# Security Policy

This repository models a realistic protocol review target. It is not intended for production
deployment without an independent security review, operational runbooks, and deployment controls.

## Supported Scope

The intended review scope is:

- `src/vault/ReverieBasketProtocol.sol`
- `src/core/ComponentRegistry.sol`
- `src/token/ReverieBasketToken.sol`
- `src/oracle/ReveriePriceOracle.sol`
- `src/policy/ReverieRiskPolicy.sol`
- `src/libraries/`
- `src/lens/`

Mocks and tests are provided only to support local validation.

## Assumptions

- Component tokens are standard ERC-20 assets.
- Oracle prices are externally governed and updated within heartbeat bounds.
- Role holders execute scheduled operations in good faith.
- Rebalances and substitutions are expected to be observable before completion.

## Reporting

Submit a concise report with impact, root cause, proof of concept, and mitigation. Avoid reporting
cosmetic issues unless they alter security assumptions.
