# Maker v3
**Brief Strategy Description**:
This strategy is based on maker-dai-delegate from monoloco (https://github.com/therealmonoloco/maker-dai-delegate) with
- Updated keeper automation & harvestTrigger override specifics.
- UniswapV3 integration.
- ySwaps integration.
- Automated testing for all maker collateral for want token universality. 

Stages of the strategy to go from v2.1 (current) to v3:
- First stage (maker v2.2): Deposit YFI into Maker, mint DAI, deposit DAI in yvDAI. With above mentioned keeper automation & harvestTrigger updates + UniswapV3 integration + ySwaps integration.
- Second stage (maker v2.3): Automated tests to deposit any collateral into Maker, mint DAI, deposit DAI in yvDAI.
- Third stage (maker v3): Deposit any collateral on Maker, mint DAI and deposit in yvDAI or into universal interface OR leverage any collateral. 

## Installation and Setup

1. [Install Brownie](https://eth-brownie.readthedocs.io/en/stable/install.html) & [Ganache-CLI](https://github.com/trufflesuite/ganache-cli), if you haven't already.

2. Sign up for [Infura](https://infura.io/) and generate an API key. Store it in the `WEB3_INFURA_PROJECT_ID` environment variable.

```bash
export WEB3_INFURA_PROJECT_ID=YourProjectID
```

3. Sign up for [Etherscan](www.etherscan.io) and generate an API key. This is required for fetching source codes of the mainnet contracts we will be interacting with. Store the API key in the `ETHERSCAN_TOKEN` environment variable.

```bash
export ETHERSCAN_TOKEN=YourApiToken
```

- Optional Use .env file
  1. Make a copy of `.env.example`
  2. Add the values for `ETHERSCAN_TOKEN` and `WEB3_INFURA_PROJECT_ID`
     NOTE: If you set up a global environment variable, that will take precedence

4. Download the mix.

```bash
brownie bake yearn-strategy
```

## Testing

To run the tests over all Maker collateral:

```
brownie test
```
