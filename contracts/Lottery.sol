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

/** @title A sample No-Loss Lottery contract with CompoundV3 USDC Lending
 * @author SiegfriedBz
 * @notice This contract is for creating an untamperable decentralized Lottery smart contract
 * @dev This implements CompoundV3, and Chainlink VRF v2 & Chainlink Keeper ("Automation")
 * @notice CompoundV3 to lend USDC and generate gains
 * @notice Chainlink VRF will pick a random number
 * @notice Chainlink Keeper has 2 roles:
 * 1. will call the function to pick a Winner, when the Lottery is in OPEN_TO_PLAY state
 * 2. will set the time during which Players can withdraw their funds, after a Lottery run
 * @notice Player can enter Lottery by:
 * 1. transfering USDC (lotteryTicketPrice) to start lending
 * 2. sending ETH (lotteryFee) to pay the Lottery
 * @notice Player gets 1 Lottery Token (LTK) by entering Lottery.
 * @notice When a Player withdraws its USDC, he transfers all its LTK to Lottery
 */

contract Lottery is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type Declaration */
    enum LotteryState {
        OPEN_TO_PLAY,
        CALCULATING_WINNER_ADDRESS, // requesting a random number from Chainlink VRF + withdrawing Lottery USDC from Compound
        CALCULATING_WINNER_GAINS,
        OPEN_TO_WITHDRAW
    }

    /* State Variables */
    // Lottery Variables
    uint256 private immutable i_lotteryFee; // ETH 18 decimals
    uint256 private immutable i_lotteryTicketPrice; // USDC 6 decimals
    uint256 private immutable i_interval; // Lottery & ChainLink Keepers
    uint256 private immutable i_intervalWithdraw; // to automate OPEN_TO_WITHDRAW -> OPEN_TO_PLAY switch
    uint256 immutable i_MAX_INT = 2**256 - 1;
    uint256 private s_endPlayTime;
    uint256 private s_endWithDrawTime;
    uint256 private s_lastTimeStamp;
    uint256 private s_newPrize;
    address[] private s_winners;
    uint256 private s_totalNumTickets; // total number of active tickets == total number of LTK owned by all Players
    mapping(address => uint256) private playerToNumTickets; // number of player's active tickets
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
    event CompoundWithdrawRequestDone();
    event SwitchToCalculatingWinnerAddress(
        uint256 indexed timeToGetWinnerAddress
    );
    event RandomWinnerRequested(uint256 indexed requestId);
    event WinnerAddressPicked(address newWinner);
    event SwitchToCalculatingWinnerGains(uint256 indexed timeToGetWinnerGains);
    event WinnerPicked(
        address indexed newWinner,
        uint256 indexed newPrize,
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
        uint256 _interval, // for Chainlink Keepers UpKeep #01
        uint256 _intervalWithdraw, // for Chainlink Keepers UpKeep #02
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
        lotteryToken = new LotteryToken(_initLTKAmount);
        /* USDC */
        usdc = ERC20(_USDCAddress);
        /* CompoundV3 */
        comet = Comet(_cometcUSDCv3Address);
    }

    /**
     * @notice function called by Player
     * note: this call contains 3 calls from front-end:
     * 1. Player calls USDC contract to transfer i_lotteryTicketPrice USDC => Lottery
     * 2. Player calls LTK contract to increase LTK allowance for Lottery. required for later Player call this.withdrawFromLottery()
     * 3. Player calls Lottery to send i_lotteryFee ETH value => Lottery
     * transfer 1 LTK Token to Player
     * add Player to the players array
     * add 1 ticket to Player playerToNumTickets mapping
     * 3. internal call by Lottery: this.approveAndSupplyCompound()
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
        // call call USDC to approve Compound & call Compound to supply
        approveAndSupplyCompound();
        emit LotteryEntered(msg.sender);
    }

    /**
     * @notice function called by Lottery after Player called this.enterLottery()
     * 1. Lottery calls USDC contract to approve (increase allowance) Compound for all current Lottery USDC balance
     * 2. Lottery supply Compound
     * 2.1 if Player is 1st Player of this Lottery round
     *  => all current Lottery USDC balance => supply Compound
     *  => set end of Playing time (s_endPlayTime) for this round, will be checked by Chainlink Keepers on this.checkUpkeep() path 02
     * 2.2 else => 1 Ticket Price USDC => supply Compound
     */
    function approveAndSupplyCompound() internal {
        // Lottery approve (increase allowance of) Compound
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
            // if Player was First Player (of this round) to call this.enterLottery()
            // => add to supply: (current First) Player TicketPrice + All previous Lottery runs deposits from active Players (still holding USDC in Lottery & LTK)
            amountToSupply = lotteryUSDCBalance;
            s_isFirstPlayer = false;
            // set s_endPlayTime for this.checkUpkeep() path 02
            s_endPlayTime = block.timestamp + i_interval;
        } else {
            // add to supply: 1 TicketPrice
            amountToSupply = i_lotteryTicketPrice;
        }
        comet.supply(address(usdc), amountToSupply);
        emit SupplyCompoundDone(amountToSupply);
    }

    /**
     * @notice function can be called by:
     * 1. this.performUpkeep() path 02 => when a new Lottery round starts, all Lottery USDC balance is used to supply Compound
     * 2. admin call on this.adminApproveAndSupplyCompound(), to allow admin to fund Lottery/Compound (without being a Player)
     * => both "1." and "2." will approve & supply Compound with ALL current Lottery USDC balance
     */
    function approveAndSupplyCompoundForALLUsdc() internal {
        // approve Compound
        uint256 lotteryUSDCBalance = getLotteryUSDCBalance();
        bool success = usdc.increaseAllowance(
            address(comet),
            lotteryUSDCBalance
        );
        if (!success) {
            revert Lottery__CompoundAllowanceFailed();
        }
        // supply Compound
        comet.supply(address(usdc), lotteryUSDCBalance);
        emit SupplyCompoundDone(lotteryUSDCBalance);
    }

    /**
     * @notice function called by this.performUpkeep() path 01, when switching Lottery state from OPEN_TO_PLAY => CALCULATING_WINNER_ADDRESS (requesting a random number from Chainlink VRF)
     * transfer all available USDC on Compound => Lottery
     * reset s_isFirstPlayer for next Lottery round
     * note: when this.withdrawfromCompound() is called, Lottery is in CALCULATING_WINNER_ADDRESS state
     */
    function withdrawfromCompound() internal {
        uint128 availableUSDC = getLotteryUSDCBalanceOnCompound();
        comet.withdraw(address(usdc), availableUSDC);
        s_isFirstPlayer = true;
        emit CompoundWithdrawRequestDone();
    }

    /**
     * @notice function called by Player to withdraw its USDC from Lottery
     * 1. Lottery call LotteryToken => transfer ALL Player's LTK to Lottery
     * 2. Lottery call USDC => Transfer Player's due USDC from Lottery to Player
     * 3. update totalNumTickets
     * 4. reset Player mapping toNumTickets
     * note: when this.withdrawfromCompound() is called, Lottery is in OPEN_TO_WITHDRAW state
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
        // transfer ALL Player's LTK => Lottery. Player gave allowance to Lottery for its LTK from front-end when entered Lottery
        uint256 ltkAmount = playerNumTickets * 10**18;
        bool success1 = lotteryToken.transferFrom(
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
        uint256 amountDueToPlayer = playerNumTickets * i_lotteryTicketPrice; // total Player's deposit in USDC
        // transfer USDC due amount to Player
        bool success2 = usdc.transfer(msg.sender, amountDueToPlayer);
        if (!success2) {
            revert Lottery__PlayerWithdrawLotteryFailed();
        }
        // update tickets
        s_totalNumTickets -= playerToNumTickets[msg.sender];
        playerToNumTickets[msg.sender] = 0;
        emit UserWithdraw(msg.sender, amountDueToPlayer);
    }

    /**
     * @dev function called by the ChainLink Keeper ("Automation") nodes
     * ChainLink Keeper look for "upkeepNeeded" to return true
     * 3 possible paths
     * -I. path 01
     * -- To return true the following is needed
     * ---1. Lottery state == OPEN_TO_PLAY
     * ---2. Lottery Time interval to Play has passed
     * ---3. Lottery has >= 1player, and Lottery is funded
     * ---4. ChainLink subscription has enough LINK
     * -II. path 02
     * ---1. Lottery state == CALCULATING_WINNER_GAINS
     * ---2.
     * ---3.
     * -II. path 03
     * -- To return true the following is needed
     * ---1. Lottery state == OPEN_TO_WITHDRAW
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
            bool timePassed = block.timestamp > s_endPlayTime;
            bool hasPlayer = (s_players.length > 0);
            bool isFunded = (address(this).balance > 0);
            upkeepNeeded = (isOPEN_TO_PLAY &&
                timePassed &&
                hasPlayer &&
                isFunded);
            performData = checkData;
        }
        // path 02
        // check if is time to calculate gains & if widthdraw from Coumpound has been mined
        if (keccak256(checkData) == keccak256(hex"02")) {
            bool isCALCULATING_WINNER_GAINS = (s_lotteryState ==
                LotteryState.CALCULATING_WINNER_GAINS);
            bool lotteryUSDCBalanceIsNOTNull = (getLotteryUSDCBalance() > 0);
            bool lotteryUSDCBalanceOnCompoundIsNull = (getLotteryUSDCBalanceOnCompound() ==
                    0);
            upkeepNeeded = (isCALCULATING_WINNER_GAINS &&
                lotteryUSDCBalanceIsNOTNull &&
                lotteryUSDCBalanceOnCompoundIsNull);
            performData = checkData;
        }

        // path 03
        if (keccak256(checkData) == keccak256(hex"03")) {
            bool isOPEN_TO_WITHDRAW = (s_lotteryState ==
                LotteryState.OPEN_TO_WITHDRAW);
            bool timeToWithDrawPassed = (block.timestamp >= s_endWithDrawTime);
            upkeepNeeded = (isOPEN_TO_WITHDRAW && timeToWithDrawPassed);
            performData = checkData;
        }
    }

    /**
     * @dev function called by the ChainLink Keeper ("Automation") nodes when checkUpkeep() returned true.
     * 3 possible paths
     * If upkeepNeeded is true:
     * -I. from path 01:
     * --I.1. Lottery calls Coumpound to transfer all available USDC => Lottery
     * --I.2. update s_endPlayTime to prevent checkUpKeep path 01 to return true before next run
     * --I.3. a request for randomness is made to ChainLink VRF
     * --I.4. LotteryState switch => CALCULATING_WINNER_ADDRESS
     *
     * -II. from path 02:
     * --II.1
     * --II.2
     *
     * -III. from path 03:
     * --III.1 LotteryState switch => OPEN_TO_PLAY
     * --III.2 Supply Coumpound with ALL Lottery USDC balance to start generating interests
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
        // GET Winner ADDRESS
        if (keccak256(performData) == keccak256(hex"01")) {
            // call Coumpound to transfer all available USDC => Lottery
            withdrawfromCompound();
            // update s_endPlayTime
            s_endPlayTime = i_MAX_INT;
            // switch LotteryState OPEN_TO_PLAY => CALCULATING_WINNER_ADDRESS
            s_lotteryState = LotteryState.CALCULATING_WINNER_ADDRESS;
            // request the random number from ChainLink VRF
            // to fulffill this request, the ChainLink nodes will call this.fulfillRandomWords()
            uint256 requestId = i_vrfCoordinator.requestRandomWords(
                i_gasLane,
                i_subscriptionId,
                REQUEST_CONFIRMATIONS,
                i_callbackGasLimit,
                NUMWORDS
            );
            emit RandomWinnerRequested(requestId);
            emit SwitchToCalculatingWinnerAddress(block.timestamp);
        }

        // path 02
        // Get Winner GAINS
        if (keccak256(performData) == keccak256(hex"02")) {
            // set Winner GAINS
            uint256 lotteryBaseUSDCValue = s_totalNumTickets *
                i_lotteryTicketPrice; // total current USDC deposit withOut interests
            uint256 lotteryCurrentUSDCBalance = getLotteryUSDCBalance(); // with interests
            // transfer GAINS to Winner if GAINS > 0
            if (lotteryCurrentUSDCBalance > lotteryBaseUSDCValue) {
                s_newPrize = lotteryCurrentUSDCBalance - lotteryBaseUSDCValue;
                bool success = usdc.transfer(s_newWinner, s_newPrize);
                if (!success) {
                    revert Lottery__TransferGainsToWinnerFailed();
                }
            } else {
                s_newPrize = 0;
            }
            // reset Players array
            s_players = new address[](0);
            // reset newWinner address
            address currentWinner = s_newWinner;
            s_newWinner = address(0);
            // switch LotteryState CALCULATING_WINNER_GAINS => OPEN_TO_WITHDRAW
            s_lotteryState = LotteryState.OPEN_TO_WITHDRAW;
            // set next endWithDrawTime
            s_endWithDrawTime = block.timestamp + i_intervalWithdraw;
            emit WinnerPicked(currentWinner, s_newPrize, block.timestamp);
            emit SwitchToOpenToWithDraw(block.timestamp);
        }

        // path 03
        // Set new Lottery round
        if (keccak256(performData) == keccak256(hex"03")) {
            // switch LotteryState OPEN_TO_WITHDRAW => OPEN_TO_PLAY
            s_lotteryState = LotteryState.OPEN_TO_PLAY;
            // supply Coumpound with ALL Lottery USDC balance
            approveAndSupplyCompoundForALLUsdc();
            emit SwitchToOpenToPlay(block.timestamp);
        }
    }

    /**
     * @dev function called by the ChainLink nodes
     * After the request for randomness is made to Chainlink VRF, a Chainlink Node call its own fulfillRandomWords to run off-chain calculation => randomWords.
     * Then, a Chainlink Node call our fulfillRandomWords (on-chain) and pass to it the requestId and the randomWords.
     * 1. set Winner
     * 2. set Winner GAINS
     * 3. transfer USDC GAINS to Winner
     * 4. reset Players array
     * 5. switch LotteryState CALCULATING_WINNER_ADDRESS => CALCULATING_WINNER_GAINS
     * 6. set next end of WithDraw Time for this round
     * note: all Players (including Winner) keep their USDC (all without gains) in Lottery for next run. Also, all Players (including Winner) keep their Lottery Tokens until they withdraw all their USDC.
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
        // switch LotteryState CALCULATING_WINNER_ADDRESS => CALCULATING_WINNER_GAINS
        s_lotteryState = LotteryState.CALCULATING_WINNER_GAINS;
        emit WinnerAddressPicked(s_newWinner);
        emit SwitchToCalculatingWinnerGains(block.timestamp);
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
     * @notice Getter for front end
     * returns the current Lottery round endPlayTime
     */
    function getEndPlayTime() external view returns (uint256) {
        return s_endPlayTime;
    }

    /**
     * @notice Getter for front end
     * returns the current Lottery round endWithDrawTime
     */
    function getEndWithDrawTime() external view returns (uint256) {
        return s_endWithDrawTime;
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
     * @notice function called by Admin, require Lottery state is OpenToPlay
     * 1. called from front-end, first: Admin send USDC to Lottery
     * 2. approve Compound for all current Lottery USDC balance
     * 3. supply Compound with all current Lottery USDC balance
     */
    function adminApproveAndSupplyCompound() external onlyOwner onlyOpenToPlay {
        approveAndSupplyCompoundForALLUsdc();
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

    /* Functions fallbacks */
    receive() external payable {
        enterLottery();
    }

    fallback() external payable {
        enterLottery();
    }
}
