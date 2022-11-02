// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

error Lottery__UnAuthorized();
error Lottery__NeedToSendCorrectAmount();
error Lottery__TransferGainsToWinnerFailed();
error Lottery__NotOPEN_TO_PLAY();
error Lottery__UpKeepNotNeeded(
    uint256 _lotteryBalance,
    uint256 _numberOfPlayers,
    uint256 _lotteryState
);
error Lottery__CompoundAllowanceFailed();
error Lottery__NotOPEN_TO_WITHDRAW();
error Lottery__PlayerHas0Ticket();
error Lottery__PlayerLTKTransferToLotteryFailed(
    address _transferTo,
    uint256 _ltkAmount
);
error Lottery__PlayerWithdrawLotteryFailed();
error Lottery__AdminWithdrawETHFailed();
error Lottery__AdminWithdrawUSDCFailed();
error Lottery__AdminCanNotPerformMyUpkeep();

// LotteryToken LTK ERC20 Mintable
import "./LotteryToken.sol";
// Chainlink VRF v2 - Verifiable Random Function
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
// Chainlink Keeper - Automation
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
// USDC ERC20
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// Compound V3
import "./interfaces/IComet.sol";

/** @title A sample Lottery contract with CompoundV3 USDC Lending
 * @author SiegfriedBz
 * @notice This contract is for creating an untamperable decentralized Lottery smart contract
 * @dev This implements Chainlink VRF v2 & Chainlink Keeper ("Automation")
 * @notice Chainlink VRF will pick a random number
 * @notice Chainlink Keeper will call the function to pick a Winner
 * @dev This implements CompoundV3 to lend USDC
 * @notice Player can enter Lottery by:
 * 1. transfering USDC (lotteryTicketPrice) to start lending
 * 2. sending ETH (lotteryFee) to pay the Lottery
 * @notice Player gets 1 Lottery Token (LTK) by entering Lottery
 */

contract Lottery is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type Declaration */
    enum LotteryState {
        OPEN_TO_PLAY,
        CALCULATING, // requesting a random number from Chainlink VRF + withdrawing Lottery USDC from Compound
        OPEN_TO_WITHDRAW
    }

    /* State Variables */
    // Lottery Variables
    uint256 private immutable i_lotteryFee; // ETH 18 decimals
    uint256 private immutable i_lotteryTicketPrice; // USDC 6 decimals
    uint256 private immutable i_initLTKAmount; // number of LTK minted during LTK deployment
    uint256 private immutable i_interval; // Lottery & ChainLink Keepers
    uint256 private immutable i_intervalWithdraw; // to automate OPEN_TO_WITHDRAW -> OPEN_TO_PLAY switch
    uint256 private s_endWithDrawTime;
    uint256 private s_lastTimeStamp;
    uint256 private s_newPrize;
    address[] private s_winners;
    uint256 private s_totalNumTickets; // total number of active tickets == total number of LTK owned by Players
    mapping(address => uint256) private playerToNumTickets; // player's active tickets number
    address private immutable i_owner;
    address private s_newWinner;
    address[] private s_players;
    LotteryState private s_lotteryState;
    bool private s_isFirstPlayer = true; // reset at each Lottery round

    // LotteryToken
    LotteryToken public lotteryToken;

    // ChainLink Keepers & VRF config
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator; // VRF
    bytes32 private immutable i_gasLane; // VRF
    uint64 private immutable i_subscriptionId; // VRF
    uint32 private immutable i_callbackGasLimit; // VRF
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // VRF
    uint32 private constant NUMWORDS = 1; // VRF

    // USDC
    ERC20 public usdc;

    // CompoundV3
    Comet public comet;

    /* Events */
    event LotteryEntered(address indexed player);
    event SupplyCompoundDone(uint256 indexed amount);
    event CompoundWithdrawRequested();
    event SwitchToCalculating(uint256 indexed timeToPlay);
    event CompoundWithdrawDone();
    event RandomWinnerRequested(uint256 indexed requestId);
    event WinnerPicked(
        address indexed s_newWinner,
        uint256 indexed s_newPrize,
        uint256 indexed winDate
    );
    event SwitchToOpenToWithDraw(uint256 indexed timeToWithDraw);
    event UserWithdraw(address indexed player, uint256 indexed amount);
    event SwitchToOpenToPlay(uint256 indexed timeToPlay);

    /* Modifiers */
    modifier onlyOwner() {
        if (i_owner != msg.sender) {
            revert Lottery__UnAuthorized();
        }
        _;
    }
    modifier onlyOpenToPlay() {
        if (s_lotteryState != LotteryState.OPEN_TO_PLAY) {
            revert Lottery__NotOPEN_TO_PLAY();
        }
        _;
    }

    /* Functions */
    constructor(
        uint256 _lotteryFee, // ETH
        uint256 _lotteryTicketPrice, // USDC
        uint256 _interval,
        uint256 _intervalWithdraw, // for UpKeep #02
        address _vrfCoordinator,
        bytes32 _gasLane,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit,
        uint256 _initLTKAmount,
        address _USDCAddress,
        address _cometcUSDCv3Address
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        /* Lottery */
        i_owner = payable(msg.sender);
        i_lotteryFee = _lotteryFee;
        i_lotteryTicketPrice = _lotteryTicketPrice;
        s_lotteryState = LotteryState.OPEN_TO_PLAY;
        i_interval = _interval;
        i_intervalWithdraw = _intervalWithdraw;
        s_lastTimeStamp = block.timestamp;
        /* ChainLink */
        i_vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        i_gasLane = _gasLane;
        i_subscriptionId = _subscriptionId;
        i_callbackGasLimit = _callbackGasLimit;
        /* LotteryToken */
        i_initLTKAmount = _initLTKAmount;
        lotteryToken = new LotteryToken(_initLTKAmount);
        /* USDC */
        usdc = ERC20(_USDCAddress);
        /* CompoundV3 */
        comet = Comet(_cometcUSDCv3Address);
    }

    /**
     * @notice function called by Player
     * note: this call contains 3 calls from front-end:
     * 1. Player calls USDC to transfer i_lotteryTicketPrice USDC => Lottery
     * 2. Player calls USDC to give allowance to Lottery to use its LTKs: required for later Player call this.withdrawFromLottery()
     * 3. Player calls Lottery to send i_lotteryFee ETH value => Lottery
     * transfer 1 Lottery Token to Player
     * add Player to the players array
     * add 1 ticket to Player playerToNumTickets mapping
     * 3. internal calls by Lottery:
     * 3.1 call USDC to approve Compound
     * 3.2 call Compound to supply USDC => Compound
     */
    function enterLottery() public payable onlyOpenToPlay {
        if (msg.value != i_lotteryFee) {
            revert Lottery__NeedToSendCorrectAmount();
        }
        // update Player's tickets & LTK
        playerToNumTickets[msg.sender] += 1;
        s_totalNumTickets += 1;
        s_players.push(msg.sender);
        lotteryToken.transfer(msg.sender, 10**18); // 1 LTK (18 decimals)
        // call Compound to supply
        approveAndSupplyCompound();
        emit LotteryEntered(msg.sender);
    }

    /**
     * @notice function called by Lottery after Player called enterLottery
     * 1. approve Compound for all current Lottery USDC balance
     * 2.1 if Player is 1st Player of this Lottery round => all current Lottery USDC balance --> supply Compound
     * 2.2 else => 1 Ticket Price USDC --> supply Compound
     */
    function approveAndSupplyCompound() internal {
        // Lottery approve Compound for all current Lottery USDC balance
        uint256 lotteryUSDCBalance = getLotteryUSDCBalance();
        bool success = usdc.increaseAllowance(
            address(comet),
            lotteryUSDCBalance
        );
        if (!success) {
            revert Lottery__CompoundAllowanceFailed();
        }
        // Lottery supply Compound
        uint256 amountToSupply;
        if (s_isFirstPlayer) {
            // if call from First Player
            // add to supply: (current First) Player TicketPrice + All previous Lottery runs deposits from active Players (still holding USDC in Lottery & LTK)
            amountToSupply = lotteryUSDCBalance;
            s_isFirstPlayer = false;
        } else {
            // add to supply: 1 TicketPrice (current Player)
            amountToSupply = i_lotteryTicketPrice;
        }
        comet.supply(address(usdc), amountToSupply);
        emit SupplyCompoundDone(amountToSupply);
    }

    /**
     * @notice function
     * 1. approve Compound for ALL current Lottery USDC balance
     * 2. all current Lottery USDC balance --> supply Compound with ALL USDC /!\
     */
    function approveAndSupplyCompoundForALLUsd() internal {
        // approve Compound for ALL current Lottery USDC balance
        uint256 lotteryUSDCBalance = getLotteryUSDCBalance();
        bool success = usdc.increaseAllowance(
            address(comet),
            lotteryUSDCBalance
        );
        if (!success) {
            revert Lottery__CompoundAllowanceFailed();
        }
        // Lottery supply Compound with ALL current Lottery USDC balance
        comet.supply(address(usdc), lotteryUSDCBalance);
        emit SupplyCompoundDone(lotteryUSDCBalance);
    }

    /**
     * @notice function called by Lottery
     * transfer all available USDC from Compound => Lottery
     * reset s_isFirstPlayer for next Lottery round
     * note: Lottery is currently in CALCULATING state
     */
    function withdrawfromCompound() internal {
        uint128 availableUSDC = getLotteryUSDCBalanceOnCompound();
        comet.withdraw(address(usdc), availableUSDC);
        s_isFirstPlayer = true;
        emit CompoundWithdrawDone();
    }

    /**
     * @notice function called by Player to withdraw its USDC from Lottery
     * 1. Player calls Lottery --> Lottery calls LotteryToken => transfer LTK From Player to Lottery
     * reset Player mapping toNumTickets
     * update totalNumTickets
     * 2. Lottery call USDC => Transfer Player's USDC from Lottery to Player
     * note: Player get MAX of (PlayerNumTokens * TicketPrice, PlayerRatio * LotteryCurrentUSDCBalance)
     * note: Lottery is currently in OPEN_TO_WITHDRAW state
     */
    function withdrawFromLottery() public {
        if (s_lotteryState != LotteryState.OPEN_TO_WITHDRAW) {
            revert Lottery__NotOPEN_TO_WITHDRAW();
        }
        uint256 playerNumTickets = playerToNumTickets[msg.sender];
        // check if Player has tickets
        if (playerNumTickets == 0) {
            revert Lottery__PlayerHas0Ticket();
        }
        // transfer LTK From Player => Lottery // Player gave allowance to Lottery for its LTK amount
        uint256 ltkAmount = playerNumTickets * 10**18;
        bool success1 = lotteryToken.transferFrom( /* address sender, address recipient, uint256 amount */
            msg.sender,
            address(this),
            ltkAmount
        );

        if (!success1) {
            revert Lottery__PlayerLTKTransferToLotteryFailed(
                address(this),
                ltkAmount
            );
        }
        // set Player due USDC
        // TODO : uint256 amountDueToPlayer = getUSDCAmountDueToPlayer(msg.sender);
        // BELOW simplified version
        uint256 amountDueToPlayer = playerNumTickets * i_lotteryTicketPrice; // withOut interests
        // transfer USDC due amount to Player
        bool success = usdc.transfer(msg.sender, amountDueToPlayer); // address recipient, uint256 amount
        if (!success) {
            revert Lottery__PlayerWithdrawLotteryFailed();
        }
        // reset
        s_totalNumTickets -= playerToNumTickets[msg.sender];
        playerToNumTickets[msg.sender] = 0;
        emit UserWithdraw(msg.sender, amountDueToPlayer);
    }

    /**
     * @dev function called by the ChainLink Keeper ("Automation") nodes
     * ChainLink Keeper look for "upkeepNeeded" to return true
     * 2 possible paths
     * -I.
     * --To return true the following is needed
     * ---1. Lottery state == "OPEN_TO_PLAY"
     * ---2. Lottery Time interval to Play has passed
     * ---3. Lottery has >= 1player, and Lottery is funded
     * ---4. ChainLink subscription has enough LINK
     * -II.
     * --To return true the following is needed
     * ---1. Lottery state == "OPEN_TO_WITHDRAW"
     * ---2. Lottery Time interval to WithDraw has Passed
     */
    function checkUpkeep(bytes memory checkData)
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // path 01
        if (keccak256(checkData) == keccak256(hex"01")) {
            bool isOPEN_TO_PLAY = (s_lotteryState == LotteryState.OPEN_TO_PLAY);
            bool timePassed = (block.timestamp - s_lastTimeStamp) > i_interval;
            bool hasPlayer = (s_players.length > 0);
            bool isFunded = (address(this).balance > 0);
            upkeepNeeded = (isOPEN_TO_PLAY &&
                timePassed &&
                hasPlayer &&
                isFunded);
            performData = checkData;
        }
        // path 02
        if (keccak256(checkData) == keccak256(hex"02")) {
            bool isOPEN_TO_WITHDRAW = (s_lotteryState ==
                LotteryState.OPEN_TO_WITHDRAW);
            bool timeToWithDrawPassed = (block.timestamp >= s_endWithDrawTime);
            upkeepNeeded = (isOPEN_TO_WITHDRAW && timeToWithDrawPassed);
            performData = checkData;
        }
    }

    /**
     * @dev function called by the ChainLink Keeper ("Automation") nodes when checkUpkeep() returned true.
     * 2 possible paths
     * If upkeepNeeded is true:
     * -I. from path 01:
     * --I.1 a request for randomness is made to ChainLink VRF
     * --I.2 LotteryState switch => CALCULATING)
     * --I.3 a call is made by Lottery to Coumpound to transfer all available USDC => Lottery
     * -II. from path 02:
     * --II.1 LotteryState switch => OPEN_TO_PLAY
     * --II.2 Supply Coumpound with ALL Lottery USDC balance
     */
    function performUpkeep(bytes memory performData) external override {
        // upkeep revalidation whatever the path
        (bool upkeepNeeded, ) = checkUpkeep(performData);
        if (!upkeepNeeded) {
            revert Lottery__UpKeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_lotteryState)
            );
        }
        // path 01
        if (keccak256(performData) == keccak256(hex"01")) {
            // switch LotteryState OPEN_TO_PLAY => CALCULATING
            s_lotteryState = LotteryState.CALCULATING;
            // request the random number from ChainLink VRF
            uint256 requestId = i_vrfCoordinator.requestRandomWords(
                i_gasLane,
                i_subscriptionId,
                REQUEST_CONFIRMATIONS,
                i_callbackGasLimit,
                NUMWORDS
            );
            // call Coumpound to transfer all available USDC => Lottery
            withdrawfromCompound();
            emit RandomWinnerRequested(requestId);
            emit CompoundWithdrawRequested();
            emit SwitchToCalculating(block.timestamp);
        }
        // path 02
        if (keccak256(performData) == keccak256(hex"02")) {
            // switch LotteryState OPEN_TO_WITHDRAW => OPEN_TO_PLAY
            s_lotteryState = LotteryState.OPEN_TO_PLAY;
            // supply Coumpound with ALL Lottery USDC balance
            approveAndSupplyCompoundForALLUsd();
            emit SwitchToOpenToPlay(block.timestamp);
        }
    }

    /**
     * @dev function called by the ChainLink nodes
     * After the request for randomness is made, a Chainlink Node call its own fulfillRandomWords to run off-chain calculation => randomWords.
     * Then, a Chainlink Node call our fulfillRandomWords (on-chain) and pass to it the requestId and the randomWords.
     * Picks Address Winner
     * Transfer Winner USDC GAINS to its wallet
     * All Players (including Winner) keep their USDC (all without gains) in Lottery for next run. Also, all Players (including Winner) keep their Lottery Tokens until they withdraw all their USDC.
     */
    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        // set Winner
        uint256 indexOfWinner = randomWords[0] % s_players.length; // to get a "random word" belonging to [0, players.length-1]. note: randomWords[0] for we expect only 1 "random word" (NUMWORDS = 1).
        address newWinner = s_players[indexOfWinner];
        s_newWinner = newWinner;
        s_winners.push(newWinner);
        s_lastTimeStamp = block.timestamp;
        // set Winner GAINS
        uint256 lotteryBaseUSDCValue = s_totalNumTickets * i_lotteryTicketPrice; // withOut interests
        uint256 lotteryCurrentUSDCBalance = getLotteryUSDCBalance(); // with interests
        // check if GAINS > 0
        if (lotteryCurrentUSDCBalance > lotteryBaseUSDCValue) {
            s_newPrize = lotteryCurrentUSDCBalance - lotteryBaseUSDCValue;
            // transfer GAINS to Winner
            bool success = usdc.transfer(newWinner, s_newPrize);
            if (!success) {
                revert Lottery__TransferGainsToWinnerFailed();
            }
        } else {
            s_newPrize = 0;
        }
        // reset Players array
        s_players = new address[](0);
        // switch LotteryState CALCULATING => OPEN_TO_WITHDRAW
        s_lotteryState = LotteryState.OPEN_TO_WITHDRAW;
        //
        // set next endWithDrawTime
        s_endWithDrawTime = block.timestamp + i_intervalWithdraw;
        //
        emit WinnerPicked(s_newWinner, s_newPrize, block.timestamp);
        emit SwitchToOpenToWithDraw(block.timestamp);
    }

    /* View/Pure functions */
    /**
     * @notice Getter for front end
     * returns the entrance fee
     */
    function getLotteryFee() external view returns (uint256) {
        return i_lotteryFee;
    }

    /**
     * @notice Getter for front end
     * returns the lottery Ticket Price
     */
    function getLotteryTicketPrice() external view returns (uint256) {
        return i_lotteryTicketPrice;
    }

    /**
     * @notice Getter for front end
     * returns the number of Lottery Tokens Minted on LTK deployment
     */
    function getLTKMintInit() external view returns (uint256) {
        return i_initLTKAmount;
    }

    /**
     * @notice Getter for front end
     */
    function getLotteryState() external view returns (uint256) {
        return uint256(s_lotteryState);
    }

    /**
     * @notice Getter for front end
     */
    function getIsFirstPlayer() external view returns (bool) {
        return s_isFirstPlayer;
    }

    /**
     * @notice Getter for front end
     * returns the Lottery round duration
     */
    function getInterval() external view returns (uint256) {
        return i_interval;
    }

    /**
     * @notice Getter
     * returns the total number of active tickets
     */
    function getTotalNumTickets() external view returns (uint256) {
        return s_totalNumTickets;
    }

    /**
     * @notice Getter for front end
     * returns the players array
     */
    function getPlayers() external view returns (address[] memory) {
        return s_players;
    }

    /**
     * @notice Getter
     * returns the Player's number of tickets
     */
    function getPlayerNumberOfTickets(address _player)
        external
        view
        returns (uint256)
    {
        return playerToNumTickets[_player];
    }

    /**
     * @notice Getter for front end
     * returns the winners array
     */
    function getWinners() external view returns (address[] memory) {
        return s_winners;
    }

    /**
     * @notice Getter for front end
     */
    function getNewWinnerPrize() external view returns (uint256) {
        return s_newPrize;
    }

    /**
     * @notice Getter for front end
     */
    function getLatestTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    /**
     * @notice Getter
     * returns the Lottery USDC current balance (available on Lottery)
     */
    function getLotteryUSDCBalance() public view returns (uint256) {
        uint256 lotteryUSDCBalance = uint256(usdc.balanceOf(address(this)));
        return lotteryUSDCBalance;
    }

    /**
     * @notice Getter
     * returns the Lottery USDC amount available on Compound
     */
    function getLotteryUSDCBalanceOnCompound()
        public
        view
        returns (uint128 balance)
    {
        balance = uint128(comet.balanceOf(address(this)));
    }

    /**
     * @notice Getter
     * returns the USDC amount due to Player
     */
    function getUSDCAmountDueToPlayer(address _player)
        public
        view
        returns (uint256)
    {
        uint256 playerNumTickets = playerToNumTickets[_player];
        uint256 amountDueToPlayer;
        uint256 playerBaseUSDCValue = playerNumTickets * i_lotteryTicketPrice; // Player USDC total deposit
        uint256 lotteryBaseUSDCValue = s_totalNumTickets * i_lotteryTicketPrice; // withOut potential interests from Compound
        uint256 lotteryCurrentUSDCBalance = getLotteryUSDCBalance(); // with potential interests
        if (lotteryCurrentUSDCBalance > lotteryBaseUSDCValue) {
            // if Compound gives positive returns
            uint256 userRatio = (playerNumTickets * 10**18) / s_totalNumTickets;
            amountDueToPlayer =
                (userRatio * lotteryCurrentUSDCBalance) /
                10**18;
        } else {
            amountDueToPlayer = playerBaseUSDCValue;
        }
        return amountDueToPlayer;
    }

    /**
     * @notice Getter for front end
     */
    function getRequestConfirmations() external pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    /**
     * @notice Getter for front end
     */
    function getNumWords() external pure returns (uint256) {
        return NUMWORDS;
    }

    /**
     * @notice Getter
     * returns the admin address
     */
    function getAdmin() external view returns (address) {
        return i_owner;
    }

    /**
     * @notice function called by Admin
     * 1. approve Compound for all current Lottery USDC balance
     * 2. all current Lottery USDC balance --> supply Compound
     */
    function adminApproveAndSupplyCompound() external onlyOwner onlyOpenToPlay {
        approveAndSupplyCompoundForALLUsd();
    }

    /**
     * @notice function for Admin
     * transfers Lottery ETH to Admin
     */
    function adminWithdrawETH() external onlyOwner {
        (bool success, ) = payable(msg.sender).call{
            value: address(this).balance
        }("");
        if (!success) {
            revert Lottery__AdminWithdrawETHFailed();
        }
    }

    /**
     * @notice function for Admin
     * Emergency. --> Trade-off: need to trust Admin.
     * transfer all available USDC from Compound => Lottery
     * /!\ transfer Lottery USDC to Admin
     */
    function adminWithdrawUSDC() external onlyOwner {
        uint128 availableUSDC = getLotteryUSDCBalanceOnCompound();
        if (availableUSDC != 0) {
            comet.withdraw(address(usdc), availableUSDC);
        }
        s_isFirstPlayer = true;
        uint256 lotteryUSDCBalance = getLotteryUSDCBalance();
        if (lotteryUSDCBalance != 0) {
            bool success = usdc.transfer(msg.sender, lotteryUSDCBalance);
            if (!success) {
                revert Lottery__AdminWithdrawUSDCFailed();
            }
        }
    }

    /* Functions fallbacks */
    receive() external payable {
        enterLottery();
    }

    fallback() external payable {
        enterLottery();
    }
}
