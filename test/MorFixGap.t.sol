// SPDX-License-Identifier: MIT
// MORPHEUS CF-MOR-1 — FIX-GAP PROOF BATTERY (2026-11-18).
// Tujuan tunggal: membuktikan DUA cabang fungsi distributeRewards yang sama pada
// DistributorV2 TERDEPLOY (0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A):
//   (i)  cabang kekurangan (balance_ < lastUnderlyingBalance): TIDAK revert, yield 0
//        (= tambalan M-02 bekerja) — pra-perbaikan kode C4 mengurangi mentah dan revert.
//   (ii) cabang donasi (transfer polos menaikkan balance_ di atas lastUnderlyingBalance):
//        pertumbuhan dihitung sebagai yield dan MOR terakru ke pool (= permukaan
//        Code4rena Low [01] hidup di kode yang sama, jumlah donasi persis [01]: 0,0011 stETH).
// READ-ONLY vs mainnet: fork lokal saja; tidak ada tx mainnet.
// Pin blok Ethereum: 26436500. RPC: https://ethereum.publicnode.com
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

interface IERC20FG {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 v) external returns (bool);
}

interface ISTETHFG {
    function sharesOf(address a) external view returns (uint256);
    function getTotalShares() external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
}

interface IDistributorFG {
    function distributeRewards(uint256 i) external;
    function getDistributedRewards(uint256 i, address p) external view returns (uint256);
    // Bentuk tuple eksplisit (pola Mor1Deep) — urutan struct DepositPool:
    // token, chainLinkPath, tokenPrice, deposited, lastUnderlyingBalance, strategy, aToken, isExist
    function depositPools(uint256 i, address p)
        external
        view
        returns (address, string memory, uint256, uint256, uint256, uint8, address, bool);
    function rewardPoolLastCalculatedTimestamp(uint256 i) external view returns (uint128);
    function undistributedRewards() external view returns (uint256);
}

interface IRewardPoolFG {
    function getPeriodRewards(uint256 i, uint128 s, uint128 e) external view returns (uint256);
}

interface IChainLinkFG {
    function getPathId(string memory p) external pure returns (bytes32);
    function setAllowedPriceUpdateDelay(address feed_, uint64 delay_) external;
}

interface IOwnableFG {
    function owner() external view returns (address);
}

contract MorFixGap is Test {
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant POOL_WETH = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant POOL_WBTC = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant POOL_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant POOL_USDT = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REW = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant CLDC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    uint256 constant FORK_BLOCK = 26436500;
    string constant RPC = "https://ethereum.publicnode.com";
    uint256 constant WARP_STEP = 90000; // > minRewardsDistributePeriod (86400, terbaca on-chain)

    address attacker;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MOR_RPC_URL", RPC), FORK_BLOCK);
        attacker = vm.addr(0xA77A);
        _unbrickFeeds();
    }

    // Sama seperti baterai Mor1Deep: longgarkan batas kebasian feed di fork
    // (prank pemilik CLDC) supaya warp tidak membekukan distributeRewards.
    function _unbrickFeeds() internal {
        address owner_ = IOwnableFG(CLDC).owner();
        address[5] memory pools = [POOL_STETH, POOL_WETH, POOL_WBTC, POOL_USDC, POOL_USDT];
        vm.startPrank(owner_, owner_);
        for (uint256 i = 0; i < 5; i++) {
            (, string memory path_, , , , , , ) = IDistributorFG(DIST).depositPools(0, pools[i]);
            bytes32 pid = IChainLinkFG(CLDC).getPathId(path_);
            for (uint256 j = 0; j < 4; j++) {
                (bool ok, bytes memory ret) = CLDC.call(abi.encodeWithSignature("dataFeeds(bytes32,uint256)", pid, j));
                if (!ok || ret.length < 32) break;
                IChainLinkFG(CLDC).setAllowedPriceUpdateDelay(abi.decode(ret, (address)), type(uint64).max);
            }
        }
        vm.stopPrank();
    }

    // stETH balanceOf berbasis shares; tulis shares langsung (pola MorpheusRun1._dealStETH).
    function _setStETHBalance(address to, uint256 wantBal) internal {
        for (uint256 slot = 0; slot < 20; slot++) {
            bytes32 key = keccak256(abi.encode(to, slot));
            vm.store(STETH, key, bytes32(uint256(1 ether)));
            if (ISTETHFG(STETH).sharesOf(to) == 1 ether) {
                uint256 shares = (wantBal * ISTETHFG(STETH).getTotalShares()) / ISTETHFG(STETH).getTotalPooledEther();
                vm.store(STETH, key, bytes32(shares));
                return;
            }
            vm.store(STETH, key, bytes32(uint256(0)));
        }
        revert("stETH shares slot not found");
    }

    function _distribute() internal returns (bool ok) {
        (ok, ) = DIST.call(abi.encodeWithSignature("distributeRewards(uint256)", 0));
    }

    function _lub() internal view returns (uint256 lub_) {
        (, , , , lub_, , , ) = IDistributorFG(DIST).depositPools(0, POOL_STETH);
    }

    function _dr() internal view returns (uint256) {
        return IDistributorFG(DIST).getDistributedRewards(0, POOL_STETH);
    }

    function _bal() internal view returns (uint256) {
        return IERC20FG(STETH).balanceOf(DIST);
    }

    // (i) KASUS KEKURANGAN — saldo aktual < saldo tercatat.
    function testFixGap_ShortfallBranch_NoRevertNoMint() public {
        require(_distribute(), "settle distribute failed");
        uint256 lub1 = _lub();
        uint256 bal1 = _bal();
        uint256 dr1 = _dr();
        console.log("FG_SHORT settle_lub", lub1);
        console.log("FG_SHORT settle_bal", bal1);
        console.log("FG_SHORT settle_dr", dr1);
        assertApproxEqAbs(lub1, bal1, 2, "after settle recorded must equal actual");

        // Simulasi penurunan saldo (rebase negatif / shortfall): -1 stETH persis dari saldo.
        _setStETHBalance(DIST, bal1 - 1 ether);
        uint256 bal2 = _bal();
        console.log("FG_SHORT reduced_bal", bal2);
        console.log("FG_SHORT shortfall_amount", lub1 - bal2);
        assertLt(bal2, lub1, "shortfall state not built");

        uint128 ts0 = IDistributorFG(DIST).rewardPoolLastCalculatedTimestamp(0);
        vm.warp(block.timestamp + WARP_STEP);
        uint256 periodRewards = IRewardPoolFG(REW).getPeriodRewards(0, ts0, uint128(block.timestamp));
        console.log("FG_SHORT period_rewards", periodRewards);
        assertGt(periodRewards, 0, "period must carry nonzero rewards");

        bool ok = _distribute();
        console.log("FG_SHORT distribute_ok", ok ? 1 : 0);
        assertTrue(ok, "distributeRewards REVERTED on shortfall (pre-fix behavior)");

        uint256 dr2 = _dr();
        uint256 lub2 = _lub();
        console.log("FG_SHORT dr_delta", dr2 - dr1);
        console.log("FG_SHORT lub_after", lub2);
        console.log("FG_SHORT undistributed_after", IDistributorFG(DIST).undistributedRewards());
        assertEq(dr2 - dr1, 0, "stETH pool must accrue 0 from the shortfall branch");
        assertApproxEqAbs(lub2, bal2, 2, "recorded balance must reset down to actual");
    }

    // (ii) KASUS DONASI — transfer polos di atas saldo tercatat (skenario persis C4 Low [01]).
    function testFixGap_DonationBranch_CountsAsYield() public {
        require(_distribute(), "settle distribute failed");
        uint256 dr1 = _dr();
        console.log("FG_DON settle_dr", dr1);
        console.log("FG_DON settle_lub", _lub());
        console.log("FG_DON settle_bal", _bal());

        // Kontrol: satu periode penuh TANPA donasi (hari tanpa yield untuk pool stETH di fork).
        uint128 ts0 = IDistributorFG(DIST).rewardPoolLastCalculatedTimestamp(0);
        vm.warp(block.timestamp + WARP_STEP);
        uint256 periodRewards1 = IRewardPoolFG(REW).getPeriodRewards(0, ts0, uint128(block.timestamp));
        require(_distribute(), "control distribute failed");
        uint256 dr2 = _dr();
        console.log("FG_DON control_period_rewards", periodRewards1);
        console.log("FG_DON control_dr_delta", dr2 - dr1);
        assertEq(dr2 - dr1, 0, "control: zero-yield period must accrue 0 to stETH pool");

        // Donasi persis [01]: 0,0011 stETH, transfer polos ke Distributor, tanpa panggilan pool.
        _setStETHBalance(attacker, 0.0011 ether);
        uint256 atkBal = IERC20FG(STETH).balanceOf(attacker);
        uint256 distBalBefore = _bal();
        vm.prank(attacker);
        IERC20FG(STETH).transfer(DIST, atkBal);
        uint256 distBalAfter = _bal();
        console.log("FG_DON attacker_sent", atkBal);
        console.log("FG_DON dist_bal_delta", distBalAfter - distBalBefore);

        uint128 ts1 = IDistributorFG(DIST).rewardPoolLastCalculatedTimestamp(0);
        vm.warp(block.timestamp + WARP_STEP);
        uint256 periodRewards2 = IRewardPoolFG(REW).getPeriodRewards(0, ts1, uint128(block.timestamp));
        require(_distribute(), "donation distribute failed");
        uint256 dr3 = _dr();
        uint256 delta = dr3 - dr2;
        console.log("FG_DON donation_period_rewards", periodRewards2);
        console.log("FG_DON donation_dr_delta", delta);
        console.log("FG_DON donation_share_ppm", (delta * 1e6) / periodRewards2);
        console.log("FG_DON lub_after", _lub());
        console.log("FG_DON bal_after", _bal());
        assertGt(delta, 0, "donation must be counted as yield (MOR accrues to the pool)");
        assertApproxEqAbs(_lub(), _bal(), 2, "recorded balance must equal actual after distribution");
    }

    // (iii) PERILAKU CABANG BARU PADA LUBANG (mata rantai 8) — dua fase:
    //   Fase A: yield jujur yang tiba SELAGI saldo masih di dalam lubang (bal < LUB)
    //           terserap tanpa dihitung (DR delta 0) dan LUB di-reset turun ke saldo aktual.
    //   Fase B: sesudah reset, saldo yang hanya kembali ke level ASAL (== saldo settle)
    //           menghasilkan DR delta > 0 — alas ukur sudah pindah turun, jadi yield
    //           pasca-reset dihitung penuh dari alas baru (di bawah semantik high-water
    //           mark lama, fase B akan bernilai 0).
    function testFixGap_ShortfallAbsorptionAndBaseReset() public {
        require(_distribute(), "settle distribute failed");
        uint256 bal0 = _bal();
        uint256 lub0 = _lub();
        uint256 dr0 = _dr();
        console.log("FG_ABS settle_bal", bal0);
        console.log("FG_ABS settle_lub", lub0);
        console.log("FG_ABS settle_dr", dr0);
        assertApproxEqAbs(lub0, bal0, 2, "settle: recorded equals actual");

        // Lubang: -1 stETH (rebase negatif / shortfall).
        _setStETHBalance(DIST, bal0 - 1 ether);
        // Yield jujur +0,5 stETH tiba SELAGI masih di dalam lubang.
        _setStETHBalance(DIST, bal0 - 0.5 ether);
        uint256 balA = _bal();
        console.log("FG_ABS phaseA_bal_in_hole", balA);
        assertLt(balA, lub0, "phase A must still be inside the hole");

        vm.warp(block.timestamp + WARP_STEP);
        require(_distribute(), "phase A distribute failed");
        uint256 drA = _dr();
        uint256 lubA = _lub();
        console.log("FG_ABS phaseA_dr_delta", drA - dr0);
        console.log("FG_ABS phaseA_lub_after", lubA);
        assertEq(drA - dr0, 0, "phase A: honest yield inside the hole must be absorbed uncounted");
        assertApproxEqAbs(lubA, balA, 2, "phase A: recorded balance must reset down to actual");

        // Fase B: +0,5 stETH lagi — saldo hanya kembali ke level settle asal.
        _setStETHBalance(DIST, balA + 0.5 ether);
        uint256 balB = _bal();
        console.log("FG_ABS phaseB_bal_back_to", balB);
        assertApproxEqAbs(balB, bal0, 10, "phase B: balance only returns to the original settle level");

        uint128 tsB = IDistributorFG(DIST).rewardPoolLastCalculatedTimestamp(0);
        vm.warp(block.timestamp + WARP_STEP);
        uint256 periodRewardsB = IRewardPoolFG(REW).getPeriodRewards(0, tsB, uint128(block.timestamp));
        require(_distribute(), "phase B distribute failed");
        uint256 drB = _dr();
        console.log("FG_ABS phaseB_period_rewards", periodRewardsB);
        console.log("FG_ABS phaseB_dr_delta", drB - drA);
        console.log("FG_ABS phaseB_lub_after", _lub());
        assertGt(drB - drA, 0, "phase B: post-reset yield must count in full from the lowered base");
    }
}
