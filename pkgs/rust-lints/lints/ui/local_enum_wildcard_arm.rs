enum State {
    Idle,
    Running,
    Paused,
}

fn busy(state: &State) -> bool {
    match state {
        State::Running => true,
        _ => false,
    }
}

fn label(state: State) -> &'static str {
    match state {
        State::Idle => "idle",
        other => {
            let _ = other;
            "active"
        }
    }
}

fn exhaustive(state: &State) -> bool {
    match state {
        State::Running => true,
        State::Idle | State::Paused => false,
    }
}

fn guarded(state: &State, ready: bool) -> bool {
    match state {
        State::Idle => false,
        _ if ready => true,
        State::Running | State::Paused => false,
    }
}

fn foreign(value: Option<u8>) -> u8 {
    match value {
        Some(value) => value,
        _ => 0,
    }
}

fn main() {
    let _ = (busy(&State::Idle), label(State::Paused), exhaustive(&State::Running));
    let _ = (guarded(&State::Idle, true), foreign(None), matches!(State::Idle, State::Idle));
}
