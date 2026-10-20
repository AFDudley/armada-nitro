// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @dev Minimal waUSDC (Aave v3 stata token) slice: ERC-4626 `deposit`/`redeem`/`convertToAssets`
/// and `balanceOf`. convertToAssets is read by the job with cast, not through this interface --
/// this is only the deposit/redeem path the script drives.
interface IRateVault {
    function deposit(uint256 amount) external returns (uint256);
    function redeem(uint256 shares) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal Aave v3 pool slice: `deposit` (supply) and `borrow`. Real signatures match
/// aave-v3-origin's IPool (/src/aave-v3-origin/src/contracts/interfaces/IPool.sol).
interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
}

/**
 * @notice E11 (arn-ced): the Aave yield (scenario 1) and redeem (scenario 4) on-chain steps, run
 * by the `armada-assets-e2e` gate job (stack/compose-jobs/armada-assets-e2e.yml) against the
 * fixturenet. The hub (testAccounts[2], the delegate) deposits USDC into the waUSDC stata token
 * (ERC-4626 `deposit`); a second test account (testAccounts[3]) supplies USDC to the Aave pool and
 * borrows USDC at LTV 75% to raise utilization; time advances by real blocks (the job sleeps);
 * then the hub redeems its waUSDC for USDC (ERC-4626 `redeem`), receiving at least the scenario 1
 * principal (1000 USDC). Lido's oracle stays unconfigured in this job (arn-ced c6: no Lido oracle
 * members, reports, or price injection) -- docs/tasks/E11-aave-lido-channels.md.
 *
 * Environment: MANIFEST_PATH (default /env/manifest.json), KEYS_DIR (default /env), HUB_RPC.
 * Each step is a separate `forge script --sig` call (job stage 2); the job itself reads the yield
 * indicators (waUSDC.convertToAssets(1e6), the Aave pool's USDC liquidityIndex) and the redeem's
 * USDC balance change with cast, before and after calling into this script.
 */
contract AssetsScenario is Script {
    // The scenario 1 principal: the hub deposits this many USDC into waUSDC (1000 USDC at 6
    // decimals). Scenario 4's redeem must return at least this principal (measured by the job's
    // USDC balance change).
    uint256 internal constant PRINCIPAL = 1_000e6;
    // Second account's Aave position: supply 500 USDC (collateral) and borrow 300 USDC, within the
    // 75% LTV cap (0.75 * 500 = 375 USDC). The borrow raises the pool's utilization so Aave yield
    // accrues during the real-block window.
    uint256 internal constant SUPPLY = 500e6;
    uint256 internal constant BORROW = 300e6;
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    struct Ctx {
        IERC20 usdc;
        address usdcAddress;
        address pool;
        address waUsdc;
        address hub;
        uint256 hubKey;
        address second;
        uint256 secondKey;
    }

    /// c3: the hub custodian deposits USDC into waUSDC (ERC-4626 `deposit`).
    function aaveDeposit() external {
        Ctx memory c = _ctx();
        vm.startBroadcast(c.hubKey);
        c.usdc.approve(c.waUsdc, PRINCIPAL);
        uint256 minted = IRateVault(c.waUsdc).deposit(PRINCIPAL);
        vm.stopBroadcast();
        require(minted > 0, 'waUSDC.deposit minted no shares');
        console2.log('hub deposited', PRINCIPAL / 1e6, 'USDC into waUSDC (ERC-4626 deposit)');
    }

    /// c3: a second account supplies USDC to the Aave pool and borrows USDC at LTV 75% to raise
    /// utilization. The job skips this call entirely under the discrimination-a flag
    /// (ASSETS_E2E_NO_BORROW=1); the yield-increased check must then fail.
    function aaveSupplyBorrow() external {
        Ctx memory c = _ctx();
        vm.startBroadcast(c.secondKey);
        c.usdc.approve(c.pool, SUPPLY);
        IAavePool(c.pool).deposit(c.usdcAddress, SUPPLY, c.second, 0);
        IAavePool(c.pool).borrow(c.usdcAddress, BORROW, VARIABLE_RATE_MODE, 0, c.second);
        vm.stopBroadcast();
        console2.log('second account supplied', SUPPLY / 1e6, 'USDC to the Aave pool');
        console2.log('second account borrowed', BORROW / 1e6, 'USDC at LTV 75%');
    }

    /// c4: the hub redeems its waUSDC for USDC (ERC-4626 `redeem`). If the hub holds no waUSDC
    /// (standalone scenario 4 on a fresh fixturenet), it deposits the principal first so the redeem
    /// has shares to redeem; the job measures the USDC balance change (must be >= PRINCIPAL).
    function aaveRedeem() external {
        Ctx memory c = _ctx();
        uint256 shares = IRateVault(c.waUsdc).balanceOf(c.hub);
        if (shares == 0) {
            // Standalone scenario 4 on a fresh fixturenet: no prior scenario 1 run. Deposit the
            // principal (1000 USDC) first so the redeem returns at least the scenario 1 principal.
            vm.startBroadcast(c.hubKey);
            c.usdc.approve(c.waUsdc, PRINCIPAL);
            shares = IRateVault(c.waUsdc).deposit(PRINCIPAL);
            vm.stopBroadcast();
            require(shares > 0, 'waUSDC.deposit (principal) minted no shares');
        }
        require(shares > 0, 'hub holds no waUSDC to redeem');
        vm.broadcast(c.hubKey);
        uint256 redeemed = IRateVault(c.waUsdc).redeem(shares);
        require(redeemed > 0, 'waUSDC.redeem returned no assets');
        console2.log('hub redeemed', shares, 'waUSDC shares');
        console2.log('redeem returned', redeemed / 1e6, 'USDC (ERC-4626 redeem)');
    }

    // ---------- helpers ----------

    function _ctx() internal view returns (Ctx memory c) {
        string memory manifest = vm.readFile(_manifestPath());
        c.usdc = IERC20(vm.parseJsonAddress(manifest, '.armada.usdc'));
        c.usdcAddress = address(c.usdc);
        c.pool = vm.parseJsonAddress(manifest, '.aave.pool');
        c.waUsdc = vm.parseJsonAddress(manifest, '.assets.waUSDC');
        // Hub = testAccounts[2] (anvil account 3, the delegate); second = testAccounts[3] (account 4).
        c.hub = vm.parseJsonAddress(manifest, '.testAccounts[2].address');
        c.second = vm.parseJsonAddress(manifest, '.testAccounts[3].address');
        string memory keysDir = vm.envOr('KEYS_DIR', string('/env'));
        string memory hubKeyFile = vm.parseJsonString(manifest, '.testAccounts[2].privateKeyFile');
        string memory secondKeyFile = vm.parseJsonString(manifest, '.testAccounts[3].privateKeyFile');
        c.hubKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', hubKeyFile)));
        c.secondKey = vm.parseUint(vm.readFile(string.concat(keysDir, '/', secondKeyFile)));
    }

    function _manifestPath() internal view returns (string memory) {
        return vm.envOr('MANIFEST_PATH', string('/env/manifest.json'));
    }
}
