pragma solidity 0.4.15;

import '../EtherToken.sol';
import '../LockedAccount.sol';
import '../Math.sol';
import '../Neumark.sol';
import '../Standards/ITokenWithDeposit.sol';
import '../TimeSource.sol';
import './ITokenOffering.sol';
import './MCommitment.sol';
import "../AccessControl/AccessControlled.sol";
import "../Reclaimable.sol";


// Consumes MCommitment
contract CommitmentBase is
    MCommitment,
    AccessControlled,
    TimeSource,
    Math,
    ITokenOffering,
    Reclaimable
{
    ////////////////////////
    // Constants
    ////////////////////////

    // share of Neumark reward platform operator gets
    uint256 public constant NEUMARK_REWARD_PLATFORM_OPERATOR_DIVISOR = 2;

    ////////////////////////
    // Immutable state
    ////////////////////////

    // locks investors capital
    LockedAccount public LOCKED_ACCOUNT;

    ITokenWithDeposit public PAYMENT_TOKEN;

    Neumark public NEUMARK;

    ////////////////////////
    // Mutable state
    ////////////////////////

    //
    // Set only once
    //

    uint256 public startDate;

    uint256 public endDate;

    uint256 public minTicket;

    uint256 public minAbsCap;

    uint256 public maxAbsCap;

    uint256 public ethEURFraction;

    //
    // Mutable
    //

    bool public finalized;

    // amount stored in LockedAccount on finalized
    uint256 public finalCommitedAmount;

    // wallet that keeps Platform Operator share of neumarks
    address public platformOperatorWallet;

    ////////////////////////
    // Constructor
    ////////////////////////

    /// declare capital commitment into Neufund ecosystem
    /// store funds in _ethToken and lock funds in _lockedAccount while issuing Neumarks along _curve
    /// commitments can be chained via long lived _lockedAccount and _nemark
    function CommitmentBase(
        IAccessPolicy accessPolicy,
        EtherToken _ethToken,
        LockedAccount _lockedAccount,
        Neumark _neumark
    )
        AccessControlled(accessPolicy)
        Reclaimable()
    {
        require(address(_ethToken) == address(_lockedAccount.assetToken()));
        require(_neumark == _lockedAccount.neumark());
        LOCKED_ACCOUNT = _lockedAccount;
        NEUMARK = _neumark;
        PAYMENT_TOKEN = _ethToken;
    }

    ////////////////////////
    // Public functions
    ////////////////////////

    function setCommitmentTerms(
        uint256 _startDate,
        uint256 _endDate,
        uint256 _minAbsCap,
        uint256 _maxAbsCap,
        uint256 _minTicket,
        uint256 _ethEurFraction,
        address _platformOperatorWallet
    )
        public
        // TODO: Access control
    {
        // set only once
        require(endDate == 0);
        require(_startDate > 0);
        require(_endDate >= _startDate);
        require(_maxAbsCap > 0);
        require(_maxAbsCap >= _minAbsCap);
        require(_platformOperatorWallet != address(0));

        startDate = _startDate;
        endDate = _endDate;

        minAbsCap = _minAbsCap;
        maxAbsCap = _maxAbsCap;

        minTicket = _minTicket;
        ethEURFraction = _ethEurFraction;
        platformOperatorWallet = _platformOperatorWallet;
    }

    function commit()
        public
        payable
    {
        // must control locked account
        require(address(LOCKED_ACCOUNT.controller()) == address(this));

        // must have terms set
        require(startDate > 0);
        require(currentTime() >= startDate);
        require(msg.value >= minTicket);
        require(!hasEnded());
        uint256 total = add(LOCKED_ACCOUNT.totalLockedAmount(), msg.value);

        // we are not sending back the difference - only full tickets
        require(total <= maxAbsCap);
        require(validCommitment());

        // get neumarks
        uint256 neumarks = giveNeumarks(msg.sender, msg.value);

        //send Money to ETH-T contract
        PAYMENT_TOKEN.deposit.value(msg.value)(address(this), msg.value);

        // make allowance for lock
        PAYMENT_TOKEN.approve(address(LOCKED_ACCOUNT), msg.value);

        // lock in lock
        LOCKED_ACCOUNT.lock(msg.sender, msg.value, neumarks);

        // convert weis into euro
        uint256 euroUlps = convertToEUR(msg.value);
        FundsInvested(msg.sender, msg.value, PAYMENT_TOKEN, euroUlps, neumarks, NEUMARK);
    }

    /// when commitment end criteria are met ANYONE can finalize
    /// can be called only once, not intended for override
    function finalize()
        public
    {
        // must end
        require(hasEnded());

        // must not be finalized
        require(!isFinalized());

        // public commitment ends ETH locking
        if (wasSuccessful()) {
            onCommitmentSuccessful();
            CommitmentCompleted(true);
        } else {
            onCommitmentFailed();
            CommitmentCompleted(false);
        }
        finalCommitedAmount = LOCKED_ACCOUNT.totalLockedAmount();
        finalized = true;
    }

    function lockedAccount()
        public
        constant
        returns (LockedAccount)
    {
        return LOCKED_ACCOUNT;
    }

    function paymentToken()
        public
        constant
        returns (ITokenWithDeposit)
    {
        return  PAYMENT_TOKEN;
    }

    function neumark()
        public
        constant
        returns (Neumark)
    {
        return NEUMARK;
    }

    /// overrides TokenOffering
    function wasSuccessful()
        public
        constant
        returns (bool)
    {
        uint256 amount = finalized ? finalCommitedAmount : LOCKED_ACCOUNT.totalLockedAmount();
        return amount >= minAbsCap;
    }

    /// overrides TokenOffering
    function hasEnded()
        public
        constant
        returns(bool)
    {
        uint256 amount = finalized ? finalCommitedAmount : LOCKED_ACCOUNT.totalLockedAmount();
        return amount >= maxAbsCap || currentTime() >= endDate;
    }

    /// overrides TokenOffering
    function isFinalized()
        public
        constant
        returns (bool)
    {
        return finalized;
    }

    /// converts `amount` in wei into EUR with 18 decimals required by Curve
    /// Neufund public commitment uses fixed EUR rate during commitment to level playing field and
    /// prevent strategic behavior around ETH/EUR volatility. equity PTOs will use oracles as they need spot prices
    function convertToEUR(uint256 amount)
        public
        constant
        returns (uint256)
    {
        return fraction(amount, ethEURFraction);
    }

    ////////////////////////
    // Internal functions
    ////////////////////////

    /// distributes neumarks on `this` balance to investor and platform operator: half half
    /// returns amount of investor part
    function distributeAndReturnInvestorNeumarks(address investor, uint256 neumarks)
        internal
        returns (uint256)
    {
        // distribute half half
        uint256 investorNeumarks = divRound(neumarks, NEUMARK_REWARD_PLATFORM_OPERATOR_DIVISOR);

        // @ remco is there a better way to distribute?
        bool isEnabled = NEUMARK.transferEnabled();
        if (!isEnabled)
            NEUMARK.enableTransfer(true);
        require(NEUMARK.transfer(investor, investorNeumarks));
        require(NEUMARK.transfer(platformOperatorWallet, neumarks - investorNeumarks));
        NEUMARK.enableTransfer(isEnabled);
        return investorNeumarks;
    }

}
