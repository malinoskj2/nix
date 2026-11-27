import ctypes
import fcntl
import hmac
import json
import os
import resource
import signal
import subprocess
import sys
import syslog
import termios
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

MAGIC = b"SKW1"
SALT = 16
NONCE = 12
TAG = 16
CRED_NAME = "secrets-age-key"
PR_SET_DUMPABLE = 4
MCL_CURRENT = 1
MCL_FUTURE = 2
STAGE_TTL = 60
MAX_PASSWORD = 4096
PAM_TIMEOUT = 30

libc = ctypes.CDLL(None, use_errno=True)


class Refused(Exception):
    pass


def harden():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_DUMPABLE)")
    # Keeps passwords, derived keys and the identity out of swap.
    if libc.mlockall(MCL_CURRENT | MCL_FUTURE) != 0:
        raise OSError(ctypes.get_errno(), "mlockall")
    os.umask(0o077)
    # passwd is setuid: drop its real uid too, so systemd-creds runs as root rather than as the user.
    if os.geteuid() == 0:
        os.setresgid(0, 0, 0)
        os.setresuid(0, 0, 0)


def wipe(buf):
    if buf:
        ctypes.memset((ctypes.c_char * len(buf)).from_buffer(buf), 0, len(buf))


def log(message):
    syslog.openlog("secret-unlock", 0, syslog.LOG_AUTH)
    syslog.syslog(syslog.LOG_NOTICE, message)


def load_config():
    with open(os.environ.get("SECRETS_CONFIG", "/etc/secrets/config.json")) as f:
        return json.load(f)


def read_fd(fd, until_newline):
    buf = bytearray(MAX_PASSWORD)
    n = 0
    one = bytearray(1)
    while n < MAX_PASSWORD:
        if os.readv(fd, [one]) == 0:
            break
        if until_newline and one[0] == 0x0A:
            break
        buf[n] = one[0]
        n += 1
    wipe(one)
    out = bytearray(n)
    out[:] = memoryview(buf)[:n]
    wipe(buf)
    return out


def prompt(text):
    """Reads one password from the terminal without echo, or a line from stdin."""
    if not sys.stdin.isatty():
        return read_fd(0, True)
    fd = os.open("/dev/tty", os.O_RDWR)
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    new[3] &= ~termios.ECHO
    try:
        os.write(fd, f"{text}: ".encode())
        termios.tcsetattr(fd, termios.TCSAFLUSH, new)
        return read_fd(fd, True)
    finally:
        termios.tcsetattr(fd, termios.TCSAFLUSH, old)
        os.write(fd, b"\n")
        os.close(fd)


def prompt_new(text):
    first = prompt(text)
    second = prompt("Again")
    try:
        if first != second:
            wipe(first)
            raise Refused("passwords differ")
    finally:
        wipe(second)
    return first


def matches_shadow(config, user, password):
    with open("/etc/shadow", "rb") as f:
        for line in f:
            fields = line.rstrip(b"\n").split(b":")
            if fields[0] == user.encode():
                stored = fields[1]
                break
        else:
            return False
    lib = ctypes.CDLL(config["unlock"]["libcrypt"])
    lib.crypt.restype = ctypes.c_char_p
    lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    phrase = ctypes.create_string_buffer(len(password) + 1)
    if password:
        ctypes.memmove(phrase, (ctypes.c_char * len(password)).from_buffer(password), len(password))
    try:
        result = lib.crypt(phrase, stored)
    finally:
        ctypes.memset(phrase, 0, len(phrase))
    return result is not None and result == stored


def kdf(password, salt):
    return Scrypt(salt=salt, length=32, n=2**17, r=8, p=1).derive(password)


def creds(config, verb, data):
    args = [config["unlock"]["systemdCreds"], verb, f"--name={CRED_NAME}", "-", "-"]
    if verb == "encrypt":
        args.insert(2, "--with-key=host+tpm2")
    return subprocess.run(args, input=bytes(data), capture_output=True, check=True, timeout=60).stdout


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def make_dirs(path):
    """Creates path and makes each new directory's entry durable in its parent."""
    missing = []
    while not os.path.isdir(path):
        missing.append(path)
        path = os.path.dirname(path)
    for directory in reversed(missing):
        os.mkdir(directory, 0o700)
        fsync_dir(os.path.dirname(directory))


def write_atomic(path, data, mode=0o600):
    """Writes, renames and fsyncs the directory, so a crash leaves the old or the new file, durably."""
    make_dirs(os.path.dirname(path))
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view) :]
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        os.unlink(tmp)
        raise
    os.close(fd)
    os.replace(tmp, path)
    fsync_dir(os.path.dirname(path))


def read_secret_file(path):
    buf = bytearray(os.path.getsize(path))
    with open(path, "rb", buffering=0) as f:
        f.readinto(buf)
    return buf


def seal(config, key, password):
    salt = os.urandom(SALT)
    nonce = os.urandom(NONCE)
    body = bytearray(len(key) + TAG)
    ChaCha20Poly1305(kdf(password, salt)).encrypt_into(nonce, key, MAGIC, body)
    return creds(config, "encrypt", MAGIC + salt + nonce + bytes(body))


def unseal(config, sealed, password):
    inner = creds(config, "decrypt", sealed)
    if not inner.startswith(MAGIC) or len(inner) < len(MAGIC) + SALT + NONCE + TAG:
        raise ValueError("not a wrapped key")
    salt = inner[len(MAGIC) : len(MAGIC) + SALT]
    nonce = inner[len(MAGIC) + SALT : len(MAGIC) + SALT + NONCE]
    body = inner[len(MAGIC) + SALT + NONCE :]
    key = bytearray(len(body) - TAG)
    ChaCha20Poly1305(kdf(password, salt)).decrypt_into(nonce, body, MAGIC, key)
    return key


def unwrap(config, password):
    with open(config["unlock"]["sealedKeyFile"], "rb") as f:
        return unseal(config, f.read(), password)


def pending_path(config):
    return os.path.join(os.path.dirname(config["unlock"]["sealedKeyFile"]), "rewrap-pending")


def rewrap(config, key, password, out):
    """Replaces out only once the new wrap is verified to unwrap to the same key."""
    staged = seal(config, key, password)
    check = unseal(config, staged, password)
    try:
        if check != key:
            raise ValueError("the new wrap doesn't round-trip")
    finally:
        wipe(check)
    write_atomic(f"{out}.new", staged)
    os.replace(f"{out}.new", out)
    fsync_dir(os.path.dirname(out))


def settle_pending(config, password):
    """Clears the pending flag only if the wrap just written still matches the shadow file.

    A password change racing this one writes the flag after its shadow update, so clearing
    first and checking the shadow file afterwards can never drop its flag. If the check
    doesn't finish, the flag goes back.
    """
    path = pending_path(config)
    try:
        if os.path.exists(path):
            os.unlink(path)
        if matches_shadow(config, config["unlock"]["user"], password):
            return True
        write_atomic(path, b"")
        return False
    except BaseException:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        try:
            write_atomic(path, b"")
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        raise


def key_dir(config):
    return os.path.dirname(config["keyFile"])


class Busy(Exception):
    pass


def lock(config, wait=True):
    make_dirs(key_dir(config))
    fd = os.open(os.path.join(key_dir(config), ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Busy()
    return fd


def unlocked(config):
    return os.path.exists(config["keyFile"]) and os.path.getsize(config["keyFile"]) > 0


def stage_dir(config):
    return os.path.join(key_dir(config), "staged")


def staged_files(config):
    directory = stage_dir(config)
    return [os.path.join(directory, n) for n in os.listdir(directory)] if os.path.isdir(directory) else []


def login_id():
    """The PAM application process, which runs both the auth and the session phase."""
    ppid = os.getppid()
    with open(f"/proc/{ppid}/stat") as f:
        start = f.read().rsplit(")", 1)[1].split()[19]
    return f"{ppid}-{start}"


def prune_stages(config):
    now = time.time()
    for path in staged_files(config):
        if now - os.path.getmtime(path) > STAGE_TTL:
            os.unlink(path)


def apply(config):
    subprocess.run(
        [config["unlock"]["systemctl"], "start", "--no-block", "secrets-apply.service"],
        check=False,
        timeout=30,
    )


def pam_auth(config, ident):
    """Unwraps into a staged file only root can read. Nothing unlocks until the session opens."""
    password = read_fd(0, False)
    staged = os.path.join(stage_dir(config), ident)
    # A retry in the same login process mustn't commit what an earlier attempt staged.
    if os.path.exists(staged):
        os.unlink(staged)
    try:
        if unlocked(config) or not password:
            return
        try:
            key = unwrap(config, password)
        except (InvalidTag, ValueError, OSError, subprocess.SubprocessError):
            return
    finally:
        wipe(password)
    try:
        # The discard is registered before the stage exists, so a stage never outlives a failed login.
        if not schedule_discard(config, ident):
            log("couldn't schedule the staged key's discard; this login leaves the secrets locked")
            return
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        try:
            write_atomic(staged, key)
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
    finally:
        wipe(key)


def schedule_discard(config, ident):
    try:
        result = subprocess.run(
            [
                config["unlock"]["systemdRun"],
                "--quiet",
                "--collect",
                f"--on-active={STAGE_TTL}",
                f"--unit=secrets-unstage-{ident}-{time.monotonic_ns()}",
                config["unlock"]["helper"],
                "discard",
                ident,
            ],
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def pam_session(config, ident):
    """Runs only for a login PAM accepted: authentication and account checks both passed."""
    staged = os.path.join(stage_dir(config), ident)
    if not os.path.exists(staged):
        if not unlocked(config):
            log("login didn't unlock the secrets: the password or this machine doesn't match the wrapped key")
        return
    if unlocked(config):
        os.unlink(staged)
        return
    os.replace(staged, config["keyFile"])
    log("secrets unlocked at login")
    apply(config)


def pam_password(config, user):
    """Rewraps with the new password once pam_unix has written it to the shadow file."""
    password = read_fd(0, False)
    try:
        if not matches_shadow(config, user, password):
            log("password change not confirmed in the shadow file; the key keeps its old wrap")
            return
        if not unlocked(config):
            write_atomic(pending_path(config), b"")
            log("password changed while the secrets were locked; run 'secret rewrap' with the old password")
            return
        key = read_secret_file(config["keyFile"])
        try:
            rewrap(config, key, password, config["unlock"]["sealedKeyFile"])
        except Exception as e:
            write_atomic(pending_path(config), b"")
            log(f"rewrapping failed ({type(e).__name__}); the key keeps its old wrap; run 'secret rewrap'")
            return
        finally:
            wipe(key)
        if settle_pending(config, password):
            log("secrets key rewrapped with the new password")
        else:
            log("the password changed again while rewrapping; run 'secret rewrap'")
    finally:
        wipe(password)


def pam(config):
    user = config["unlock"]["user"]
    if os.environ.get("PAM_USER") != user or not os.path.exists(config["unlock"]["sealedKeyFile"]):
        return
    kind = os.environ.get("PAM_TYPE")
    # Login never waits on a `secret` command holding the lock; it proceeds with the secrets as they are.
    try:
        fd = lock(config, wait=False)
    except Busy:
        if kind == "password":
            password = read_fd(0, False)
            try:
                if matches_shadow(config, user, password):
                    write_atomic(pending_path(config), b"")
                    log("another secret command held the key; the key keeps its old wrap; run 'secret rewrap'")
            finally:
                wipe(password)
        else:
            log("another secret command held the key; this login left the secrets as they were")
        return
    try:
        prune_stages(config)
        if kind == "auth":
            pam_auth(config, login_id())
        elif kind == "open_session":
            pam_session(config, login_id())
        elif kind == "password":
            pam_password(config, user)
    finally:
        os.close(fd)


def unwrap_with(config, password):
    try:
        return unwrap(config, password)
    except (InvalidTag, ValueError, OSError, subprocess.SubprocessError):
        raise Refused("wrong password, or the key was sealed on another machine")


def wrap_with(config, key, password, out):
    user = config["unlock"]["user"]
    if not matches_shadow(config, user, password):
        raise Refused(f"that isn't {user}'s current login password")
    rewrap(config, key, password, out)


def new_password(config):
    return prompt_new(f"Login password for {config['unlock']['user']}")


def locked_section(config, work, *secrets):
    """Prompts happen before this, so a waiting prompt never holds the lock that logins take."""
    try:
        fd = lock(config)
        try:
            work()
        finally:
            os.close(fd)
    finally:
        for buf in secrets:
            wipe(buf)


def command(config, args):
    name = args[0] if args else ""
    sealed = config["unlock"]["sealedKeyFile"]
    if name == "init":
        if os.path.exists(sealed):
            raise Refused(f"{sealed} exists; use rewrap")
        password = new_password(config)

        def init():
            if os.path.exists(sealed):
                raise Refused(f"{sealed} exists; use rewrap")
            key = read_secret_file(config["keyFile"])
            try:
                wrap_with(config, key, password, sealed)
            finally:
                wipe(key)

        locked_section(config, init, password)
    elif name == "unlock":
        if unlocked(config):
            return
        password = prompt("Login password")

        def unlock():
            if unlocked(config):
                return
            key = unwrap_with(config, password)
            try:
                write_atomic(config["keyFile"], key)
            finally:
                wipe(key)

        locked_section(config, unlock, password)
    elif name == "lock":
        locked_section(
            config,
            lambda: [os.unlink(p) for p in [config["keyFile"], *staged_files(config)] if os.path.exists(p)],
        )
    elif name == "rewrap":
        old = bytearray() if unlocked(config) else prompt("Old login password")
        try:
            new = new_password(config)
        except BaseException:
            wipe(old)
            raise

        def rewrap_key():
            if unlocked(config):
                key = read_secret_file(config["keyFile"])
            elif old:
                key = unwrap_with(config, old)
            else:
                raise Refused("the secrets were locked meanwhile; run rewrap again")
            try:
                wrap_with(config, key, new, sealed)
                write_atomic(config["keyFile"], key)
            finally:
                wipe(key)
            if not settle_pending(config, new):
                raise Refused("the password changed while rewrapping; run rewrap again with the new one")

        locked_section(config, rewrap_key, old, new)
    elif name == "wrap-into" and len(args) == 3:
        password = new_password(config)

        def wrap_into():
            key = read_secret_file(args[1])
            try:
                wrap_with(config, key, password, args[2])
            finally:
                wipe(key)

        locked_section(config, wrap_into, password)
    elif name == "migrate" and len(args) == 2:
        legacy = args[1]
        password = prompt("Login password") if os.path.exists(sealed) else new_password(config)

        def migrate():
            """Publishes the live key only once a wrap of exactly this key is on disk, durably."""
            key = read_secret_file(legacy)
            try:
                if os.path.exists(sealed):
                    held = unwrap_with(config, password)
                    try:
                        if not hmac.compare_digest(held, key):
                            raise Refused(f"{sealed} holds a different key; {legacy} is unchanged")
                    finally:
                        wipe(held)
                    with open(sealed, "rb") as f:
                        os.fsync(f.fileno())
                    fsync_dir(os.path.dirname(sealed))
                else:
                    wrap_with(config, key, password, sealed)
                if unlocked(config):
                    live = read_secret_file(config["keyFile"])
                    try:
                        if not hmac.compare_digest(live, key):
                            raise Refused("a different host key is unlocked")
                    finally:
                        wipe(live)
                else:
                    write_atomic(config["keyFile"], key)
            finally:
                wipe(key)

        locked_section(config, migrate, password)
    elif name == "unwrap-to" and len(args) == 2:
        password = prompt("Login password")

        def unwrap_to():
            key = unwrap_with(config, password)
            try:
                write_atomic(args[1], key)
            finally:
                wipe(key)

        locked_section(config, unwrap_to, password)
    elif name == "discard" and len(args) == 2:
        ident = os.path.basename(args[1])

        def discard():
            for path in staged_files(config):
                if os.path.basename(path).split(".")[0] == ident:
                    os.unlink(path)

        locked_section(config, discard)
    else:
        raise Refused(
            "usage: secret-unlock init|unlock|lock|rewrap|migrate LEGACY|unwrap-to OUT|wrap-into KEY OUT|discard ID|pam"
        )


def timed_out(signum, frame):
    raise TimeoutError()


def main():
    if sys.argv[1:2] == ["pam"]:
        # Login must never fail or wait on this; any problem leaves the secrets locked.
        try:
            signal.signal(signal.SIGALRM, timed_out)
            signal.alarm(PAM_TIMEOUT)
            harden()
            pam(load_config())
        except Exception as e:
            log(f"secret-unlock failed: {type(e).__name__}")
        return 0
    try:
        harden()
        command(load_config(), sys.argv[1:])
    except Refused as e:
        print(f"secret-unlock: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
