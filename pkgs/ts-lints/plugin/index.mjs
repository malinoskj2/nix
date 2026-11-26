import noBarrelFile from "./rules/no-barrel-file.mjs";
import noBooleanLiteralArgument from "./rules/no-boolean-literal-argument.mjs";
import noCatchAllModule from "./rules/no-catch-all-module.mjs";
import noDoubleAssertion from "./rules/no-double-assertion.mjs";
import noErrorMessageMatching from "./rules/no-error-message-matching.mjs";
import noFileHeaderComment from "./rules/no-file-header-comment.mjs";
import noSwallowedCatch from "./rules/no-swallowed-catch.mjs";
import noSyncCallInAsync from "./rules/no-sync-call-in-async.mjs";
import noUnboundedPromiseAll from "./rules/no-unbounded-promise-all.mjs";
import noUnvalidatedParse from "./rules/no-unvalidated-parse.mjs";
import vueComposableCallPosition from "./rules/vue-composable-call-position.mjs";
import vueLazyRouteComponent from "./rules/vue-lazy-route-component.mjs";
import vueNoIndexKey from "./rules/vue-no-index-key.mjs";
import vueNoRandomKey from "./rules/vue-no-random-key.mjs";
import vueNoStringInjectionKey from "./rules/vue-no-string-injection-key.mjs";
import vueRouterGuardNoNext from "./rules/vue-router-guard-no-next.mjs";
import vueStoreDestructure from "./rules/vue-store-destructure.mjs";
import vueWatchSourceGetter from "./rules/vue-watch-source-getter.mjs";

export default {
  meta: { name: "eslint-plugin-jesse", version: "1.0.0", namespace: "jesse" },
  rules: {
    "no-barrel-file": noBarrelFile,
    "no-boolean-literal-argument": noBooleanLiteralArgument,
    "no-catch-all-module": noCatchAllModule,
    "no-double-assertion": noDoubleAssertion,
    "no-error-message-matching": noErrorMessageMatching,
    "no-file-header-comment": noFileHeaderComment,
    "no-swallowed-catch": noSwallowedCatch,
    "no-sync-call-in-async": noSyncCallInAsync,
    "no-unbounded-promise-all": noUnboundedPromiseAll,
    "no-unvalidated-parse": noUnvalidatedParse,
    "vue-composable-call-position": vueComposableCallPosition,
    "vue-lazy-route-component": vueLazyRouteComponent,
    "vue-no-index-key": vueNoIndexKey,
    "vue-no-random-key": vueNoRandomKey,
    "vue-no-string-injection-key": vueNoStringInjectionKey,
    "vue-router-guard-no-next": vueRouterGuardNoNext,
    "vue-store-destructure": vueStoreDestructure,
    "vue-watch-source-getter": vueWatchSourceGetter,
  },
};
