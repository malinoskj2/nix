import { after, describe, it } from "node:test";
import { RuleTester as TypedRuleTester } from "@typescript-eslint/rule-tester";
import { RuleTester } from "eslint";

TypedRuleTester.afterAll = after;
TypedRuleTester.describe = describe;
TypedRuleTester.it = it;
TypedRuleTester.itOnly = it.only;
RuleTester.describe = describe;
RuleTester.it = it;
RuleTester.itOnly = it.only;

export { RuleTester, TypedRuleTester };
