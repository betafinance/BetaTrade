

pragma solidity >=0.5.0 <0.7.0;

import '@uniswap/v2-core/contracts/interfaces/IPancakeFactory.sol';
import '@uniswap/v2-core/contracts/interfaces/IPancakePair.sol';

import './interfaces/IERC20.sol';
import './libraries/EnumerableSet.sol';
import './libraries/SafeMath.sol';
import './Ownable.sol';

interface IBeta is IERC20 {
    function mint(address to, uint256 amount) external returns (bool);
}

interface IOracle {
    function update(address tokenA, address tokenB) external;

    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut);
}

contract SwapMining is Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _whitelist;

    // BETA tokens created per block
    uint256 public betaPerBlock;
    // The block number when BETA mining starts.
    uint256 public startBlock;
    // How many blocks are halved
    uint256 public halvingPeriod = 5256000;
    // Total allocation points
    uint256 public totalAllocPoint = 0;
    IOracle public oracle;
    // router address
    address public router;
    // factory address
    IPancakeFactory public factory;
    // beta token address
    IBeta public beta;
    // Calculate price based on HUSD
    address public targetToken;
    // pair corresponding pid
    mapping(address => uint256) public pairOfPid;
    // Dev address.
    address public devaddr;

    constructor(
        IBeta _beta,
        IPancakeFactory _factory,
        IOracle _oracle,
        address _router,
        address _targetToken,
        uint256 _betaPerBlock,
        uint256 _startBlock
    ) public {
        beta = _beta;
        factory = _factory;
        oracle = _oracle;
        router = _router;
        targetToken = _targetToken;
        betaPerBlock = _betaPerBlock;
        startBlock = _startBlock;
        devaddr = msg.sender;
    }

    struct UserInfo {
        uint256 quantity;       // How many LP tokens the user has provided
        uint256 blockNumber;    // Last transaction block
    }

    struct PoolInfo {
        address pair;           // Trading pairs that can be mined
        uint256 quantity;       // Current amount of LPs
        uint256 totalQuantity;  // All quantity
        uint256 allocPoint;     // How many allocation points assigned to this pool
        uint256 allocBetaAmount; // How many BETAs
        uint256 lastRewardBlock;// Last transaction block
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;


    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function setStartBlock(uint256 _newStartBlock) public onlyOwner {
        require(_newStartBlock > startBlock, "start too early");
        startBlock = _newStartBlock;
    }

    function setDev(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }


    function addPair(uint256 _allocPoint, address _pair, bool _withUpdate) public onlyOwner {
        require(_pair != address(0), "_pair is zero address");
        if (_withUpdate) {
            massMintPools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        pair : _pair,
        quantity : 0,
        totalQuantity : 0,
        allocPoint : _allocPoint,
        allocBetaAmount : 0,
        lastRewardBlock : lastRewardBlock
        }));
        pairOfPid[_pair] = poolLength() - 1;
    }

    // Update the allocPoint of the pool
    function setPair(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massMintPools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the number of beta produced by each block
    function setBetaPerBlock(uint256 _newPerBlock) public onlyOwner {
        massMintPools();
        betaPerBlock = _newPerBlock;
    }

    // Only tokens in the whitelist can be mined BETA
    function addWhitelist(address _addToken) public onlyOwner returns (bool) {
        require(_addToken != address(0), "SwapMining: token is zero address");
        return EnumerableSet.add(_whitelist, _addToken);
    }

    function delWhitelist(address _delToken) public onlyOwner returns (bool) {
        require(_delToken != address(0), "SwapMining: token is zero address");
        return EnumerableSet.remove(_whitelist, _delToken);
    }

    function getWhitelistLength() public view returns (uint256) {
        return EnumerableSet.length(_whitelist);
    }

    function isWhitelist(address _token) public view returns (bool) {
        return EnumerableSet.contains(_whitelist, _token);
    }

    function getWhitelist(uint256 _index) public view returns (address){
        require(_index <= getWhitelistLength() - 1, "SwapMining: index out of bounds");
        return EnumerableSet.at(_whitelist, _index);
    }

    function setHalvingPeriod(uint256 _block) public onlyOwner {
        halvingPeriod = _block;
    }

    function setRouter(address newRouter) public onlyOwner {
        require(newRouter != address(0), "SwapMining: new router is zero address");
        router = newRouter;
    }

    function setOracle(IOracle _oracle) public onlyOwner {
        require(address(_oracle) != address(0), "SwapMining: new oracle is zero address");
        oracle = _oracle;
    }

    // At what phase
    function phase(uint256 blockNumber) public view returns (uint256) {
        if (halvingPeriod == 0) {
            return 0;
        }
        if (blockNumber > startBlock) {
            return (blockNumber.sub(startBlock).sub(1)).div(halvingPeriod);
        }
        return 0;
    }

    function phase() public view returns (uint256) {
        return phase(block.number);
    }

    function reward(uint256 blockNumber) public view returns (uint256) {
        uint256 _phase = phase(blockNumber);
        return betaPerBlock.div(2 ** _phase);
    }

    function reward() public view returns (uint256) {
        return reward(block.number);
    }

    // Rewards for the current block
    function getBetaReward(uint256 _lastRewardBlock) public view returns (uint256) {
        require(_lastRewardBlock <= block.number, "SwapMining: must be little than the current block number");
        uint256 blockReward = 0;
        uint256 n = phase(_lastRewardBlock);
        uint256 m = phase(block.number);
        // If it crosses the cycle
        while (n < m) {
            n++;
            // Get the last block of the previous cycle
            uint256 r = n.mul(halvingPeriod).add(startBlock);
            // Get rewards from previous periods
            blockReward = blockReward.add((r.sub(_lastRewardBlock)).mul(reward(r)));
            _lastRewardBlock = r;
        }
        blockReward = blockReward.add((block.number.sub(_lastRewardBlock)).mul(reward(block.number)));
        return blockReward;
    }
 
    // Update all pools Called when updating allocPoint and setting new blocks
    function massMintPools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            mint(pid);
        }
    }

    function mint(uint256 _pid) public returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return false;
        }
        uint256 blockReward = getBetaReward(pool.lastRewardBlock);
        if (blockReward <= 0) {
            return false;
        }
        // Calculate the rewards obtained by the pool based on the allocPoint
        uint256 betaReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        beta.mint(address(this), betaReward);
        beta.mint(devaddr, betaReward.div(10));
        // Increase the number of tokens in the current pool
        pool.allocBetaAmount = pool.allocBetaAmount.add(betaReward);
        pool.lastRewardBlock = block.number;
        return true;
    }

    // swapMining only router
    function swap(address account, address input, address output, uint256 amount) public onlyRouter returns (bool) {
        require(account != address(0), "SwapMining: taker swap account is zero address");
        require(input != address(0), "SwapMining: taker swap input is zero address");
        require(output != address(0), "SwapMining: taker swap output is zero address");

        if (poolLength() <= 0) {
            return false;
        }

        if (!isWhitelist(input) || !isWhitelist(output)) {
            return false;
        }

        address pair = IPancakeFactory(factory).getPair(input, output);

        PoolInfo storage pool = poolInfo[pairOfPid[pair]];
        // If it does not exist or the allocPoint is 0 then return
        if (pool.pair != pair || pool.allocPoint <= 0) {
            return false;
        }

        uint256 quantity = getQuantity(output, amount, targetToken);
        if (quantity <= 0) {
            return false;
        }

        mint(pairOfPid[pair]);

        pool.quantity = pool.quantity.add(quantity);
        pool.totalQuantity = pool.totalQuantity.add(quantity);
        UserInfo storage user = userInfo[pairOfPid[pair]][account];
        user.quantity = user.quantity.add(quantity);
        user.blockNumber = block.number;
        return true;
    }

    // The user withdraws all the transaction rewards of the pool
    function takerWithdraw() public {
        uint256 userSub;
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][msg.sender];
            if (user.quantity > 0) {
                mint(pid);
                // The reward held by the user in this pool
                uint256 userReward = pool.allocBetaAmount.mul(user.quantity).div(pool.quantity);
                pool.quantity = pool.quantity.sub(user.quantity);
                pool.allocBetaAmount = pool.allocBetaAmount.sub(userReward);
                user.quantity = 0;
                user.blockNumber = block.number;
                userSub = userSub.add(userReward);
            }
        }
        if (userSub <= 0) {
            return;
        }
        beta.transfer(msg.sender, userSub);
    }

    // Get rewards from users in the current pool
    function getUserReward(uint256 _pid) public view returns (uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: pool id out of bound");
        uint256 userSub;
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][msg.sender];
        if (user.quantity > 0) {
            uint256 blockReward = getBetaReward(pool.lastRewardBlock);
            uint256 betaReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
            userSub = userSub.add((pool.allocBetaAmount.add(betaReward)).mul(user.quantity).div(pool.quantity));
        }
        //Beta available to users, User transaction amount
        return (userSub, user.quantity);
    }

    function getUserRewardTotal() public view returns (uint256, uint256) {
        uint256 userSub;
        uint256 userQuantity;
        for (uint256 _pid = 0; _pid < poolInfo.length; _pid++) {
            PoolInfo memory pool = poolInfo[_pid];
            UserInfo memory user = userInfo[_pid][msg.sender];
            if (user.quantity > 0) {
                uint256 blockReward = getBetaReward(pool.lastRewardBlock);
                uint256 betaReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
                userSub = userSub.add((pool.allocBetaAmount.add(betaReward)).mul(user.quantity).div(pool.quantity));
                userQuantity = userQuantity.add(user.quantity);
            }
        }
        return (userSub, userQuantity);
    }

    // Get details of the pool
    function getPoolInfo(uint256 _pid) public view returns (address, address, uint256, uint256, uint256, uint256){
        require(_pid <= poolInfo.length - 1, "SwapMining: pool id out of bound");
        PoolInfo memory pool = poolInfo[_pid];
        address token0 = IPancakePair(pool.pair).token0();
        address token1 = IPancakePair(pool.pair).token1();
        uint256 betaAmount = pool.allocBetaAmount;
        uint256 blockReward = getBetaReward(pool.lastRewardBlock);
        uint256 betaReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
        betaAmount = betaAmount.add(betaReward);
        //token0,token1,Pool remaining reward,Total /Current transaction volume of the pool
        return (token0, token1, betaAmount, pool.totalQuantity, pool.quantity, pool.allocPoint);
    }

    function getPoolInfoTotal() public view returns (uint256, uint256, uint256) {
        uint256 unclaimedBetaAmount;
        uint256 totalQuantity;
        uint256 currentQuantity;
        for (uint256 _pid = 0; _pid < poolInfo.length; _pid++) {
            PoolInfo memory pool = poolInfo[_pid];
            uint256 blockReward = getBetaReward(pool.lastRewardBlock);
            uint256 betaReward = blockReward.mul(pool.allocPoint).div(totalAllocPoint);
            unclaimedBetaAmount = unclaimedBetaAmount.add(pool.allocBetaAmount.add(betaReward));
            totalQuantity = totalQuantity.add(pool.totalQuantity);
            currentQuantity = currentQuantity.add(pool.quantity);
        }
        return (unclaimedBetaAmount, totalQuantity, currentQuantity);
    }

    modifier onlyRouter() {
        require(msg.sender == router, "SwapMining: caller is not the router");
        _;
    }

    function getQuantity(address outputToken, uint256 outputAmount, address anchorToken) public view returns (uint256) {
        uint256 quantity = 0;
        if (outputToken == anchorToken) {
            quantity = outputAmount;
        } else if (IPancakeFactory(factory).getPair(outputToken, anchorToken) != address(0)) {
            quantity = IOracle(oracle).consult(outputToken, outputAmount, anchorToken);
        } else {
            uint256 length = getWhitelistLength();
            for (uint256 index = 0; index < length; index++) {
                address intermediate = getWhitelist(index);
                if (IPancakeFactory(factory).getPair(outputToken, intermediate) != address(0) && IPancakeFactory(factory).getPair(intermediate, anchorToken) != address(0)) {
                    uint256 interQuantity = IOracle(oracle).consult(outputToken, outputAmount, intermediate);
                    quantity = IOracle(oracle).consult(intermediate, interQuantity, anchorToken);
                    break;
                }
            }
        }
        return quantity;
    }

}
