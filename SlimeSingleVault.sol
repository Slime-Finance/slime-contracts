//ON TEST
pragma solidity ^0.6.12;

import './BEP20.sol';   
import './SafeMath.sol'; 
import './IBEP20.sol';  
import './SafeBEP20.sol';   
import './ReentrancyGuard.sol';

interface IUniswapRouter {
    function swapExactTokensForTokens(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);
}
 
interface ISmartChef {
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
    function pendingReward(address _user) external view returns (uint256);
    function userInfo(address _user) external view returns (uint256, uint256);
    function emergencyWithdraw() external;
    function rewardToken() external view returns (address);
}
 
 //  referral
interface SlimeFriends {
    function setSlimeFriend(address farmer, address referrer) external;
    function getSlimeFriend(address farmer) external view returns (address);
}
contract Pausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor () internal {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(_paused, "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}
 // CakeToken with Governance.
contract SlimeToken is BEP20  {
    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
       
    }
    function burn(address _from, uint256 _amount) external onlyOwner {
        _burn(_from, _amount);
         
    }
 
  constructor(string memory name, string memory symbol) public BEP20(name,symbol) {
       
  
    }
}
/**
 * @dev Implementation of a strategy to get yields from selectively farming the most profitable CAKE pool.
 * PancakeSwap is an automated market maker (“AMM”) that allows two tokens to be exchanged on the Binance Smart Chain.
 * It is fast, cheap, and allows anyone to participate.
 *
 * The strategy simply deposits whatever funds it receives from the vault into the selected pool (SmartChef). 
 * Rewards generated by the SmartChef can be harvested, swapped for more CAKE, and deposited again for compound farming.
 * When harvesting you can select a poolId to deposit the funds in any whitelisted pool after each harvest.
 *
 * Whitelisted pools can be added by the owner with a delay of 2 days before being approved as a harvest target.
 */

 contract IRewardDistributionRecipient is Ownable {
    address public rewardReferral;
    address public rewardVote;
 

    function setRewardReferral(address _rewardReferral) external onlyOwner {
        rewardReferral = _rewardReferral;
    }
 
}
contract SlimeSingleVault is Ownable, Pausable ,IRewardDistributionRecipient {
    using SafeBEP20 for IBEP20;
    using Address for address;
    using SafeMath for uint256;   
    
    /**
     * @dev Pool Management Data Structures
     * Pool - Struct for pools that have been approved and are ready to be used. 
     * UpcomingPool - Struct for pools that have not been approved. Have to wait for {approvalDelay} after their proposedTime.
     */
    struct Pool {
        address smartchef;
        address output;
        address cunirouter; 
        address[] coutputToMainRoute;
        uint256 added;
        bool enabled;  
    } 

    Pool[] public usingPools;


    Pool public actualPool;
 
    event ApprovePool(address smartchef);


    event AddPool(address _address);
    event disablePool(address _address);
    event changeActualPool(address _address);
    event transferToken(address _address,address to,uint256 amount);
    event stopPoolWork(address _address);
    event pause();
    event unpause();
    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {main} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {bifi} - BeefyFinance token, used to send funds to the treasury.
     * {output} - Token generated by staking CAKE. Changes depending on the selected pool.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); 
    address constant public gobernance = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    
   address[] public wbnbToGobernanceRoute = [wbnb, gobernance];
    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {smartchef} - Currently selected SmartChef contract. Stake CAKE, get {output} token.
     */
    address constant public unirouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    
    /**
     * @dev Beefy Contracts:
     * {rewards} - Reward pool where the strategy fee earnings will go.
     * {treasury} - Address of the BeefyFinance treasury
     * {vault} - Address of the vault that controls the strategy's funds.
     */
    address constant public rewardsAddress = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasuryAddress = address(0x0);

    uint256 constant public approvalDelay = 500000;

    address public devSlime;
    
    uint constant public devFee = 5;
    uint constant public hunterFee = 5; 
    uint constant public treasuryFee = 5;

    uint constant public  maxFee = 50;
    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {outputToCakeRoute} - Route we take to get from {output} into {cake}.
     * {outputToWbnbRoute} - Route we take to get from {output} into {wbnb}.
     * {wbnbTogobernanceRoute} - Route we take to get from {wbnb} into {gobernance}.
     */
    address[] public outputToMainRoute;  
      
    /**
     * @dev Initializes the strategy with a pool whitelist and vault that it will use.
     */
 
      IBEP20 public main;
      
      address public mainToken;
      
        
     SlimeToken public stoken;
       
      constructor (
        address _token,  
        string memory stoken_name,
        string memory stoken_ticker 
    ) public  {
         mainToken= _token; 
         main = IBEP20(_token);
         stoken= new SlimeToken(stoken_name,stoken_ticker);
         dev_slime=owner();
 
        IBEP20(wbnb).safeApprove(unirouter, uint(-1));
    }

    modifier validatePoolByPid(uint256 _pid) {
    require (_pid < poolLength() , "Pool does not exist") ;
    _;
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() external view returns (uint256) {
        return balanceOf().mul(1e18).div(stoken.totalSupply());
    }

     
    function depositAll(address referrer) external {
        deposit(main.balanceOf(msg.sender),referrer);
    }
    
    
     function deposit(uint _amount,address referrer) public {
        uint256 _pool = balanceOf();
        uint256 _before = main.balanceOf(address(this));
        main.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _after = main.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (stoken.totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(stoken.totalSupply())).div(_pool);
        }
        
        
          if (shares>0 && rewardReferral != address(0) && referrer != address(0)) {
            SlimeFriends(rewardReferral).setSlimeFriend (msg.sender, referrer);
            }
        
        stoken.mint(msg.sender, shares); 
        
        
        uint256 mainBal = IBEP20(main).balanceOf(address(this));
      
        ISmartChef(actualPool.smartchef).deposit(mainBal);
        
        
    }
    
 
  function depositHunter(uint _amount,address _to) internal { 
        uint256 _pool = balanceOf(); 
        uint256 shares = 0;
        if (stoken.totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(stoken.totalSupply())).div(_pool);
        }
        stoken.mint(_to, shares);
        
        
    }
    

     function withdrawAll() external {
        withdraw(stoken.balanceOf(msg.sender));
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function withdraw(uint256 _shares) public {
        uint256 r = ( balanceOf().mul(_shares)).div(stoken.totalSupply());
      stoken.burn(msg.sender, _shares);

        uint b = main.balanceOf(address(this));
        if (b < r) {
            uint _withdraw = r.sub(b);
             chefWithdraw(_withdraw);
            uint _after = main.balanceOf(address(this));
            uint _diff = _after.sub(b);
            if (_diff < _withdraw) {
                r = b.add(_diff);
            }
        }
   
        IBEP20(main).safeTransfer(msg.sender, r);
    }
    
    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {cake} from the SmartChef and returns it to the vault.
     */
    function chefWithdraw(uint256 _amount) internal returns (uint256) {
      
        uint256 mainBal = IBEP20(main).balanceOf(address(this));
         
        if (mainBal < _amount) {    
            ISmartChef(actualPool.smartchef).withdraw(_amount.sub(mainBal));  
            mainBal = IBEP20(main).balanceOf(address(this));
        }

        if (mainBal > _amount) {
            mainBal = _amount;    
        }
                
        return mainBal;
    }
 
 

     function harvestPool(bool hunterReinvest,address hunterTo) public whenNotPaused
    { 
         uint256  previusBal = IBEP20(actualPool.output).balanceOf(address(this)); 
        
          ISmartChef(actualPool.smartchef).deposit(0);
          
         //si es igual significa que es stake, no hace falta hacer swap del token reward al principal
        if(actualPool.output!=mainToken )
        {
            uint256 outputBal = IBEP20(actualPool.output).balanceOf(address(this));
            IUniswapRouter(actualPool.cunirouter).swapExactTokensForTokens(outputBal, 0, actualPool.coutputToMainRoute, address(this), now.add(600));
        }
  
        uint256 actualBal = IBEP20(actualPool.output).balanceOf(address(this));
        uint256 totalHarvested =   actualBal.sub(previusBal); 

        payFees(hunterReinvest,hunterTo,totalHarvested);
        uint256 mainBal = IBEP20(main).balanceOf(address(this));
      
        ISmartChef(actualPool.smartchef).deposit(mainBal);
    }

 
 
     /**
     * @dev Swaps whatever {output} it has for more cake.
     */
    function payFees(bool hunterReinvest,address hunterTo,uint256 _rewardsAmmount) internal {

        if(_rewardsAmmount<=0)
            return;
        //swap farm token to initial token
 
        uint totalfees = DEV_FEE.add(HUNTER_FEE).add(TREASURE_FEE); 
    
        uint256 cakeFeesBalance =_rewardsAmmount.mul(totalfees).div(1000);
        //hunter reward
        if(HUNTER_FEE>0)
        { uint256 hunterFee = cakeFeesBalance.mul(HUNTER_FEE).div(totalfees);
           
            if(hunterReinvest)
            {
                depositHunter(hunterFee,hunterTo);
            }else{
                
               IBEP20(main).safeTransfer(hunterTo, hunterFee);
            }
        }
        //dev reward
        if(DEV_FEE>0)
        {
            uint256 rewardsFee = cakeFeesBalance.mul(DEV_FEE).div(totalfees);
            IBEP20(main).safeTransfer(dev_slime, rewardsFee);
        }
        if(TREASURE_FEE>0)
        {
            uint256 treasuryFee = cakeFeesBalance.mul(TREASURE_FEE).div(totalfees);
            IBEP20(main).safeTransfer(treasury, treasuryFee);
         } 
    }
 
    //if any param is diferent or mannually dev add
    function addPool(address _smartchef, address _output,address _unirouter,address[] memory _outputToMainRoute
    ) external onlyOwner nonReentrant {
  
        IBEP20(_output).safeApprove(unirouter, uint(-1));
        IBEP20(main).approve(_smartchef,uint256(-1));
 
        bool _enabled =false;

        if(usingPoolsLength()==0) 
            _enabled=true;

        Pool memory pool= Pool({ 
            smartchef: _smartchef, 
            output: _output,
            cunirouter:_unirouter, 
            coutputToMainRoute: _outputToMainRoute,
            enabled:_enabled,
            added: block.timestamp
        });
 
         usingPools.push(pool);

        if(usingPoolsLength()==0)  
            actualPool= pool;

        emit AddPool(  _smartchef);
     
    }
  
    function disablePool(uint256 poolId) external onlyOwner nonReentrant  validatePoolByPid(poolId) {
        Pool storage pool = usingPools[poolId]; 

        IBEP20(main).approve(pool.smartchef,0);
        pool.enabled=false;
    }
 
     function enablePool(uint256 poolId) external onlyOwner nonReentrant  validatePoolByPid(poolId) { 
        Pool storage pool = usingPools[poolId]; 

        require(pool.added.add(approvalDelay) < block.timestamp, "Delay has not passed");

        IBEP20(pool.output).safeApprove(pool.cunirouter, uint(-1));
        IBEP20(main).approve(pool.smartchef,uint256(-1));

        pool.enabled = true; 

        emit ApprovePool(_smartchef);
    }

    function changeActualPool(uint256 poolId) external onlyOwner nonReentrant  validatePoolByPid(poolId)
    {
        Pool memory pool = usingPools[poolId]; 

        if(pool.enabled)
          {
            chefWithdraw(balanceOfPool());
            harvestPool(false,dev_slime);     
            actualPool=pool;
          }  
 
    }
  
    //withdraw other tokens diferent to stake & reward
    function transferToken(address tokenAddress,address to,uint256 _ammount) external onlyOwner{
          require(tokenAddress!=mainToken && tokenAddress!=actualPool.output);

          IBEP20(tokenAddress).safeTransfer(to,_ammount);

          emit transferToken(tokenAddress,to,_ammount);
    }
   
 
    /**
     * Retiro de emergencia
     */
    function stopPoolWork() external onlyOwner nonReentrant{
       _pause(); 
      
        ISmartChef(actualPool.smartchef).emergencyWithdraw(); 

       IBEP20(main).approve(actualPool.smartchef,0);
        actualPool.enabled=false;

       emit stopPoolWork(actualPool.smartchef);
    }
    /**
     * @dev Pauses the strat.
     */
    function pause() external onlyOwner {
        _pause();
        emit pause();
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();
        emit unpause(); 
    }

 
    function isPoolEnabled(uint256 id) external view   returns(bool)
    {
        return usingPools[id].enabled ;
    }    
 
    /**
     * @dev Helper function for UIs to know how many pools there are.
     */
    function usingPoolsLength() public view returns (uint256) {
        return usingPools.length;
    }
 

    /**
     * @dev Function to calculate the total underlaying {cake} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the current SmartChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfMain().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much cake the contract holds.
     */
    function balanceOfMain() public view returns (uint256) {
        return IBEP20(main).balanceOf(address(this));
    }
 
    function balanceOfPool()  public view returns (uint256)
    { 
     uint256 _amount=0;
       (_amount, ) =  ISmartChef(actualPool.smartchef).userInfo(address(this));
       
       return _amount;
    }

     function pendingReward(address who) public view returns (uint256)
    { 
        if(who==address(0x0))
            who = address(this);

        return ISmartChef(actualPool.smartchef).pendingReward(who);
    }
}