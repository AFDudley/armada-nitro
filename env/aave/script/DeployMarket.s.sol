// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from 'forge-std/Script.sol';

import 'aave-v3-origin/src/deployments/interfaces/IMarketReportTypes.sol';
import {AaveV3BatchOrchestration} from 'aave-v3-origin/src/deployments/projects/aave-v3-batched/AaveV3BatchOrchestration.sol';
import {IPool} from 'aave-v3-origin/src/contracts/interfaces/IPool.sol';
import {IACLManager} from 'aave-v3-origin/src/contracts/interfaces/IACLManager.sol';
import {MockAggregator} from 'aave-v3-origin/src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {IStataTokenFactory} from 'aave-v3-origin/src/contracts/extensions/stata-token/interfaces/IStataTokenFactory.sol';

import {EnvMarketInput} from '../EnvMarketInput.sol';
import {EnvUsdcListingPayload} from '../EnvUsdcListingPayload.sol';

/**
 * @title DeployMarket
 * @notice Deploys this environment's Aave v3 market (env/reconciler/modules/aave.py step 1),
 * the fixturenet's USDC MockAggregator price feed (step 2), lists USDC on it through
 * `AaveV3ConfigEngine.listAssets` at mainnet's reserve parameters (step 3), and creates the
 * `waUSDC` stata token (step 4) -- all four E4 deploy steps in one broadcast, since steps 2-4
 * each need an address the previous step only produces at runtime (the market's configEngine
 * and pool addresses, the price feed address). Writes every address the manifest needs to
 * ./reports/aave-market.json (this project's own fs_permissions grant write access there;
 * env/reconciler/modules/aave.py creates the directory first, since `vm.writeJson` does not).
 */
contract DeployMarket is Script, EnvMarketInput {
  function run() external {
    address deployer = msg.sender;

    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory report
    ) = _getMarketInput(deployer);

    vm.startBroadcast();
    report = AaveV3BatchOrchestration.deployAaveV3(deployer, roles, config, flags, report);
    vm.stopBroadcast();

    address usdc = vm.envAddress('AAVE_USDC');

    vm.startBroadcast();
    MockAggregator priceFeed = new MockAggregator(1e8);
    vm.stopBroadcast();

    EnvUsdcListingPayload.ReserveParams memory params = EnvUsdcListingPayload.ReserveParams({
      ltv: vm.envUint('AAVE_USDC_LTV'),
      liqThreshold: vm.envUint('AAVE_USDC_LIQ_THRESHOLD'),
      liqBonus: vm.envUint('AAVE_USDC_LIQ_BONUS'),
      reserveFactor: vm.envUint('AAVE_USDC_RESERVE_FACTOR'),
      liqProtocolFee: vm.envUint('AAVE_USDC_LIQ_PROTOCOL_FEE'),
      supplyCap: vm.envUint('AAVE_USDC_SUPPLY_CAP'),
      borrowCap: vm.envUint('AAVE_USDC_BORROW_CAP'),
      optimalUsageRatio: vm.envUint('AAVE_USDC_OPTIMAL_USAGE_RATIO'),
      baseVariableBorrowRate: vm.envUint('AAVE_USDC_BASE_VARIABLE_BORROW_RATE'),
      variableRateSlope1: vm.envUint('AAVE_USDC_VARIABLE_RATE_SLOPE1'),
      variableRateSlope2: vm.envUint('AAVE_USDC_VARIABLE_RATE_SLOPE2')
    });

    vm.startBroadcast();
    EnvUsdcListingPayload payload = new EnvUsdcListingPayload(
      usdc,
      address(priceFeed),
      report.configEngine,
      params
    );
    IACLManager(report.aclManager).addPoolAdmin(address(payload));
    payload.execute();
    vm.stopBroadcast();

    vm.startBroadcast();
    address[] memory underlyings = new address[](1);
    underlyings[0] = usdc;
    address[] memory stataTokens = IStataTokenFactory(report.staticATokenFactoryProxy).createStataTokens(
      underlyings
    );
    vm.stopBroadcast();

    address aUsdc = IPool(report.poolProxy).getReserveData(usdc).aTokenAddress;

    string memory json = 'aave-market';
    vm.serializeAddress(json, 'poolAddressesProvider', report.poolAddressesProvider);
    vm.serializeAddress(json, 'pool', report.poolProxy);
    vm.serializeAddress(json, 'aclManager', report.aclManager);
    vm.serializeAddress(json, 'configEngine', report.configEngine);
    vm.serializeAddress(json, 'aUSDC', aUsdc);
    vm.serializeAddress(json, 'stataTokenFactory', report.staticATokenFactoryProxy);
    vm.serializeAddress(json, 'usdcPriceFeed', address(priceFeed));
    string memory output = vm.serializeAddress(json, 'waUSDC', stataTokens[0]);
    vm.writeJson(output, './reports/aave-market.json');
  }
}
