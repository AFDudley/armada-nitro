// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3Payload} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';
import {IAaveV3ConfigEngine as IEngine} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {EngineFlags} from 'aave-v3-origin/src/contracts/extensions/v3-config-engine/EngineFlags.sol';

/**
 * @title EnvUsdcListingPayload
 * @notice Lists this environment's USDC on the Aave v3 market's `AaveV3ConfigEngine`
 * (src/contracts/extensions/v3-config-engine/AaveV3ConfigEngine.sol), with every parameter
 * the postconditions gate (ltv, liquidation threshold, liquidation bonus, reserve factor,
 * supply/borrow caps, interest-rate curve) equal to mainnet Aave v3's USDC reserve, as
 * recorded in env/aave/mainnet-usdc-reserve.json (docs/tasks/E4-aave.md step 3). Mirrors the
 * shape of aave-v3-origin's own `AaveV3MockListing` test fixture
 * (tests/extensions/v3-config-engine/mocks/AaveV3MockListing.sol), except every numeric field
 * is a constructor argument instead of a hard-coded mock value, since these values come from a
 * live mainnet read rather than a fixed test fixture.
 *
 * @dev Deployed once, granted `POOL_ADMIN_ROLE` by the market's deployer (who holds
 * `ACLManager`'s `DEFAULT_ADMIN_ROLE` as `roles.marketOwner`), then `execute()`d once: like
 * `AaveV3Payload.execute()`, this `functionDelegateCall`s the config engine, running its code
 * in this contract's own identity, so `PoolConfigurator`/`Pool` see this contract -- not the
 * deployer -- as `msg.sender` and require this contract's own `POOL_ADMIN_ROLE`.
 */
contract EnvUsdcListingPayload is AaveV3Payload {
  struct ReserveParams {
    uint256 ltv;
    uint256 liqThreshold;
    uint256 liqBonus;
    uint256 reserveFactor;
    uint256 liqProtocolFee;
    uint256 supplyCap;
    uint256 borrowCap;
    uint256 optimalUsageRatio;
    uint256 baseVariableBorrowRate;
    uint256 variableRateSlope1;
    uint256 variableRateSlope2;
  }

  address public immutable ASSET;
  address public immutable PRICE_FEED;
  ReserveParams private _params;

  constructor(
    address asset,
    address priceFeed,
    address configEngine,
    ReserveParams memory params
  ) AaveV3Payload(IEngine(configEngine)) {
    ASSET = asset;
    PRICE_FEED = priceFeed;
    _params = params;
  }

  function newListings() public view override returns (IEngine.Listing[] memory) {
    IEngine.Listing[] memory listings = new IEngine.Listing[](1);
    listings[0] = IEngine.Listing({
      asset: ASSET,
      assetSymbol: 'USDC',
      priceFeed: PRICE_FEED,
      rateStrategyParams: IEngine.InterestRateInputData({
        optimalUsageRatio: _params.optimalUsageRatio,
        baseVariableBorrowRate: _params.baseVariableBorrowRate,
        variableRateSlope1: _params.variableRateSlope1,
        variableRateSlope2: _params.variableRateSlope2
      }),
      enabledToBorrow: EngineFlags.ENABLED,
      flashloanable: EngineFlags.ENABLED,
      ltv: _params.ltv,
      liqThreshold: _params.liqThreshold,
      liqBonus: _params.liqBonus,
      reserveFactor: _params.reserveFactor,
      supplyCap: _params.supplyCap,
      borrowCap: _params.borrowCap,
      liqProtocolFee: _params.liqProtocolFee
    });
    return listings;
  }

  function getPoolContext() public pure override returns (IEngine.PoolContext memory) {
    return IEngine.PoolContext({networkName: 'Armada Nitro Fixturenet', networkAbbreviation: 'ArmFix'});
  }
}
