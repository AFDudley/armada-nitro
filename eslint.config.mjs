// ESLint for the repo's TypeScript: the gate scripts (env/gates) and the Lido step
// scripts (env/lido). They run inside other projects' trees (armada-poc, lido-core),
// whose dependencies are not installed here, so the rules are the syntax-level
// typescript-eslint recommended set, not the type-aware one.
import tseslint from "typescript-eslint";

export default tseslint.config(...tseslint.configs.recommended);
