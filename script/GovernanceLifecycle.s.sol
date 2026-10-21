// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Script, console2} from 'forge-std/Script.sol';
import {Vm} from 'forge-std/Vm.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PrivacyPool} from 'armada/privacy-pool/PrivacyPool.sol';
import {MockUSDCV2} from 'armada/cctp/MockUSDCV2.sol';
import {ArmadaToken} from 'armada/governance/ArmadaToken.sol';
import {ArmadaCrowdfund} from 'armada/crowdfund/ArmadaCrowdfund.sol';
import {CommitmentPreimage} from 'src/armada/IArmadaPool.sol';
import {ArmadaNotes} from '../test/helpers/ArmadaNotes.sol';

/// @dev Minimal view of the vendored Baal contract (lib/armada-poc/lib/baal/contracts/Baal.sol):
/// only the calls this scenario needs to sponsor and vote on one trivial, no-op proposal.
interface IBaalMin {
    function submitProposal(
        bytes calldata proposalData,
        uint32 expiration,
        uint256 baalGas,
        string calldata details
    ) external payable returns (uint256);
    function submitVote(uint32 id, bool approved) external;
    function proposalCount() external view returns (uint32);
    function sponsorThreshold() external view returns (uint256);
    function proposalOffering() external view returns (uint256);
    function sharesToken() external view returns (address);
}

/// @dev Minimal view of the vendored Gnosis Safe (lib/armada-poc/lib/safe-contracts): only the
/// two read-only calls the report step needs.
interface ISafeMin {
    function isOwner(address owner) external view returns (bool);
    function getThreshold() external view returns (uint256);
}

/**
 * @notice G7a: the first half of the Baal governance lifecycle (crowdfund commit through one
 * Baal vote) against the real G1-G6 contracts, on the fixturenet. Matches
 * `script/LocalScenario.s.sol`'s structure -- one `forge script --sig` call per phase, each
 * reading the deployment manifests `env/gates/governance-stack/governance-stack.ts` (the G7-deploy
 * gate, arn-2be) writes into `lib/armada-poc/deployments/`:
 *
 *   hub-v3.json              MockUSDCV2 (the deployer is a minter by construction)
 *   privacy-pool-hub.json    PrivacyPool
 *   governance-hub.json      ArmadaToken (ARM), the Safe (`.contracts.treasury`), RevenueLock
 *   baal-safe-hub.json       Baal, the Safe (`.contracts.safe`), ShieldedRagequit, loot token
 *   crowdfund-hub.json       ArmadaCrowdfund
 *
 * ArmadaCrowdfund.MIN_SALE is $1,000,000 and ArmadaCrowdfund.finalize() refunds everyone (no ARM,
 * no shielded proceeds) below that -- one account's commit cannot reach it alone: HOP0_CAP_USDC
 * caps a single hop-0 seed at $15,000 (ArmadaCrowdfund.sol `_effectiveCap`). `fund()` below
 * whitelists SEED_COUNT (67) synthetic hop-0 seeds (deterministic keys derived from a fixed
 * label, funded with ETH for gas and USDC from the MockUSDCV2 deployer-minter) that each commit
 * the full $15,000 cap, for $1,005,000 of capped demand -- just over MIN_SALE. The CLAIMANT
 * (seed index 0) is the one address this scenario carries through claim/delegate/vote; the other
 * 66 seeds exist only to clear the sale's minimum-raise floor and never claim.
 *
 * Phases:
 *   fund      transfers ARM into the crowdfund and calls loadArm(); whitelists the seeds; funds
 *             and commits all SEED_COUNT seeds (including the claimant) at the hop-0 cap
 *   finalize  advances past the commit window and finalizes -- G5's shield of the sale proceeds
 *             as one Safe-owned pool note lands here
 *   claim     the claimant claims ARM, delegating to themselves in the same call
 *   sponsor   the claimant sponsors one trivial no-op Baal proposal (a zero-length multisend --
 *             a pure signal, nothing Baal executes if it ever reaches Ready)
 *   vote      the claimant casts one Baal vote on that proposal
 *   report    reads live chain state (not simulated state) and emits one JSON line
 *
 * Environment: DEPLOYER_KEY, POC_DEPLOYMENTS_DIR (default lib/armada-poc/deployments).
 */
contract GovernanceLifecycle is Script {
    uint256 internal constant SEED_COUNT = 67;
    uint256 internal constant HOP0_CAP_USDC = 15_000e6;

    string internal constant PROPOSAL_ID_FILE = 'deployments/governance-lifecycle-proposal-id';
    string internal constant START_BLOCK_FILE = 'deployments/governance-lifecycle-start-block';
    uint256 internal constant SEED_GAS_WEI = 1 ether;

    struct Ctx {
        PrivacyPool privacyPool;
        MockUSDCV2 usdc;
        ArmadaCrowdfund crowdfund;
        ArmadaToken armToken;
        IBaalMin baal;
        ISafeMin safe;
        uint256 deployerKey;
    }

    /// @dev Seed `i`'s private key: a fixed label so every phase call (a fresh `forge script`
    /// process) derives the identical set of addresses without persisting any key material.
    function _seedKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode('G7A_SEED', i)));
    }

    function _claimantKey() internal pure returns (uint256) {
        return _seedKey(0);
    }

    function fund() external {
        Ctx memory c = _ctx();
        vm.createDir('deployments', true);
        vm.writeFile(START_BLOCK_FILE, vm.toString(block.number));

        // ARM pre-load: deploy_crowdfund.ts's own initWhitelist already whitelisted the deployer
        // for transfer (arn-2be's governance-stack.ts comment), so the deployer can move ARM into
        // the crowdfund; loadArm() is permissionless and idempotent.
        uint256 requiredArm = (c.crowdfund.MAX_SALE() * 1e18) / c.crowdfund.ARM_PRICE();
        if (c.armToken.balanceOf(address(c.crowdfund)) < requiredArm) {
            vm.broadcast(c.deployerKey);
            c.armToken.transfer(address(c.crowdfund), requiredArm);
        }
        if (!c.crowdfund.armLoaded()) {
            vm.broadcast(c.deployerKey);
            c.crowdfund.loadArm();
        }

        address[] memory seeds = new address[](SEED_COUNT);
        for (uint256 i = 0; i < SEED_COUNT; i++) {
            seeds[i] = vm.addr(_seedKey(i));
        }
        vm.broadcast(c.deployerKey);
        c.crowdfund.addSeeds(seeds);

        for (uint256 i = 0; i < SEED_COUNT; i++) {
            address seed = seeds[i];
            vm.broadcast(c.deployerKey);
            payable(seed).transfer(SEED_GAS_WEI);
            vm.broadcast(c.deployerKey);
            c.usdc.mint(seed, HOP0_CAP_USDC);

            uint256 seedKey = _seedKey(i);
            vm.startBroadcast(seedKey);
            c.usdc.approve(address(c.crowdfund), HOP0_CAP_USDC);
            c.crowdfund.commit(0, HOP0_CAP_USDC);
            vm.stopBroadcast();
        }
        console2.log('funded + committed', SEED_COUNT, 'seeds at the hop-0 cap each');
    }

    /// @dev `windowEnd` is read from the live crowdfund contract (not assumed). On a real chain
    /// `block.timestamp` only advances with real wall-clock time -- there is no time-travel RPC
    /// on a real geth fixturenet (unlike Anvil's `evm_increaseTime`) -- so the caller must wait
    /// out the real gap itself (the gate script does this with `sleep`) before invoking this.
    function finalize() external {
        Ctx memory c = _ctx();
        require(block.timestamp > c.crowdfund.windowEnd(), 'GovernanceLifecycle: window not yet ended on chain');
        vm.broadcast(c.deployerKey);
        c.crowdfund.finalize();
        console2.log('finalized the crowdfund');
    }

    /// @dev Claims ARM and delegates to the claimant itself in the same call, so the claimant's
    /// own ARM balance is immediately also its Baal voting power (ERC20Votes requires an
    /// explicit delegation -- an undelegated balance carries zero votes).
    function claim() external {
        Ctx memory c = _ctx();
        uint256 claimantKey = _claimantKey();
        address claimant = vm.addr(claimantKey);
        vm.broadcast(claimantKey);
        c.crowdfund.claim(claimant);
        console2.log('claimed ARM; claimant balance', c.armToken.balanceOf(claimant));
    }

    /// @dev A zero-length multisend proposalData is a pure signal: Baal's `multisend.multiSend`
    /// on an empty payload is a no-op, so this proposal can never change chain state even if a
    /// future step processed it (out of scope here -- G7a stops at the vote, per the brief).
    function sponsor() external {
        Ctx memory c = _ctx();
        uint256 claimantKey = _claimantKey();
        address claimant = vm.addr(claimantKey);
        uint256 votes = ArmadaToken(c.baal.sharesToken()).getVotes(claimant);
        uint256 value = votes >= c.baal.sponsorThreshold() ? 0 : c.baal.proposalOffering();
        vm.broadcast(claimantKey);
        c.baal.submitProposal{value: value}('', 0, 0, 'G7a: signaling proposal');
        uint32 id = c.baal.proposalCount();
        vm.createDir('deployments', true);
        vm.writeFile(PROPOSAL_ID_FILE, vm.toString(uint256(id)));
        console2.log('sponsored Baal proposal', id);
    }

    function vote() external {
        Ctx memory c = _ctx();
        uint32 id = uint32(vm.parseUint(vm.readFile(PROPOSAL_ID_FILE)));
        vm.broadcast(_claimantKey());
        c.baal.submitVote(id, true);
        console2.log('cast one Baal vote on proposal', id);
    }

    /// @notice Reads live chain state (not simulated state) and emits one JSON line with the
    /// results the gate's acceptance oracle checks:
    ///   proceeds_shielded                the crowdfund's sale proceeds landed in the pool's
    ///                                     Shield log as a Safe-owned note, not a plain balance
    ///   claimant_arm_positive / safe_owner_is_baal / safe_threshold   G2's wiring, re-verified
    ///   vote_power_equals_claimant_arm   the one recorded Baal vote's weight equals the
    ///                                     claimant's ARM voting power
    function report() external {
        Ctx memory c = _ctx();
        address claimant = vm.addr(_claimantKey());

        bool proceedsShielded = _proceedsShielded(c);
        uint256 claimantArm = c.armToken.balanceOf(claimant);
        bool claimantArmPositive = claimantArm > 0;
        bool safeOwnerIsBaal = c.safe.isOwner(address(c.baal));
        uint256 safeThreshold = c.safe.getThreshold();
        uint256 votePower = ArmadaToken(c.baal.sharesToken()).getVotes(claimant);
        bool votePowerEqualsClaimantArm = votePower == claimantArm;

        console2.log('proceeds_shielded', proceedsShielded);
        console2.log('claimant_arm_positive', claimantArmPositive);
        console2.log('safe_owner_is_baal', safeOwnerIsBaal);
        console2.log('safe_threshold', safeThreshold);
        console2.log('vote_power_equals_claimant_arm', votePowerEqualsClaimantArm);

        string memory json = string.concat(
            '{"proceeds_shielded":',
            proceedsShielded ? 'true' : 'false',
            ',"claimant_arm_positive":',
            claimantArmPositive ? 'true' : 'false',
            ',"safe_owner_is_baal":',
            safeOwnerIsBaal ? 'true' : 'false',
            ',"safe_threshold":',
            vm.toString(safeThreshold),
            ',"vote_power_equals_claimant_arm":',
            votePowerEqualsClaimantArm ? 'true' : 'false',
            '}'
        );
        vm.createDir('deployments', true);
        vm.writeFile('deployments/governance-lifecycle-report.json', json);
        console2.log('REPORT_JSON=', json);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Walks the pool's Shield log since this run's start block for a note whose npk is
    /// the Safe's feeRecipient-derived npk (the same npk ArmadaCrowdfund.finalize() reads to
    /// shield the sale proceeds) and whose token is this run's USDC. Finding one proves the
    /// proceeds landed as a shielded pool note owned by the Safe, not a plain USDC transfer.
    function _proceedsShielded(Ctx memory c) internal view returns (bool) {
        bytes32 safeNpk = c.privacyPool.feeRecipient();
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ArmadaNotes.SHIELD_EVENT;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(
            vm.parseUint(vm.readFile(START_BLOCK_FILE)),
            block.number,
            address(c.privacyPool),
            topics
        );
        for (uint256 i = 0; i < logs.length; i++) {
            (CommitmentPreimage[] memory notes, ) = ArmadaNotes.decodeShield(logs[i].data);
            for (uint256 j = 0; j < notes.length; j++) {
                if (
                    notes[j].npk == safeNpk &&
                    notes[j].token.tokenAddress == address(c.usdc) &&
                    notes[j].value > 0
                ) {
                    return true;
                }
            }
        }
        return false;
    }

    function _pocDeploymentsDir() internal view returns (string memory) {
        return vm.envOr('POC_DEPLOYMENTS_DIR', string('lib/armada-poc/deployments'));
    }

    function _ctx() internal view returns (Ctx memory c) {
        string memory dir = _pocDeploymentsDir();
        string memory cctp = vm.readFile(string.concat(dir, '/hub-v3.json'));
        string memory governance = vm.readFile(string.concat(dir, '/governance-hub.json'));
        string memory baalSafe = vm.readFile(string.concat(dir, '/baal-safe-hub.json'));
        string memory crowdfund = vm.readFile(string.concat(dir, '/crowdfund-hub.json'));
        string memory pool = vm.readFile(string.concat(dir, '/privacy-pool-hub.json'));

        c.privacyPool = PrivacyPool(payable(vm.parseJsonAddress(pool, '.contracts.privacyPool')));
        c.usdc = MockUSDCV2(vm.parseJsonAddress(cctp, '.contracts.usdc'));
        c.crowdfund = ArmadaCrowdfund(vm.parseJsonAddress(crowdfund, '.contracts.crowdfund'));
        c.armToken = ArmadaToken(vm.parseJsonAddress(governance, '.contracts.armToken'));
        c.baal = IBaalMin(vm.parseJsonAddress(baalSafe, '.contracts.baal'));
        c.safe = ISafeMin(vm.parseJsonAddress(baalSafe, '.contracts.safe'));

        c.deployerKey = vm.envUint('DEPLOYER_KEY');
    }
}
