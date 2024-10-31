// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC721} from "../interfaces/IERC721.sol";
import {IERC20} from "../interfaces/IERC20.sol";

contract NFTLendingFacet {
    
    
    event LoanCreated(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed nftContract,
        uint256 tokenId,
        uint256 loanAmount,
        uint256 interestRate,
        uint256 duration
    );
    event LoanFunded(uint256 indexed loanId, address indexed lender);
    event LoanRepaid(uint256 indexed loanId);
    event LoanLiquidated(uint256 indexed loanId);
    event PlatformFeeUpdated(uint256 newFee);
    event DurationLimitsUpdated(uint256 minDuration, uint256 maxDuration);


    error InvalidDuration();
    error InvalidAmount();
    error InvalidRate();
    error NotNFTOwner();
    error NFTNotApproved();
    error LoanAlreadyFunded();
    error LoanAlreadyLiquidatedOrRepaid();
    error InvalidLoan();
    error TransferFailed();
    error LoanNotActive();
    error NotBorrower();
    error NotLender();
    error LoanNotExpired();
    error FeeTooHigh();

    function initializeLendingFacet() external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.platformFee = 50; // 0.5%
        ds.min_duration = 1 days;
        ds.max_duration = 365 days;
    }

    function createLoan(
        address _nftContract,
        uint256 _tokenId,
        uint256 _loanAmount,
        uint256 _interestRate,
        uint256 _duration
    ) external returns (uint256) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        
        if (_duration < ds.min_duration || _duration > ds.max_duration) 
            revert InvalidDuration();
        if (_loanAmount == 0) 
            revert InvalidAmount();
        if (_interestRate == 0) 
            revert InvalidRate();

        IERC721 nft = IERC721(_nftContract);
        if (nft.ownerOf(_tokenId) != msg.sender) 
            revert NotNFTOwner();
        if (!nft.isApprovedForAll(msg.sender, address(this)) && 
            nft.getApproved(_tokenId) != address(this)) 
            revert NFTNotApproved();

        uint256 loanId = ds.totalLoans++;
        
        ds.loans[loanId] = LibDiamond.Loan({
            borrower: msg.sender,
            lender: address(0),
            nftContract: _nftContract,
            tokenId: _tokenId,
            loanAmount: _loanAmount,
            interestRate: _interestRate,
            startTime: 0,
            duration: _duration,
            isActive: false,
            isRepaid: false
        });

        
        nft.transferFrom(msg.sender, address(this), _tokenId);

        emit LoanCreated(
            loanId,
            msg.sender,
            _nftContract,
            _tokenId,
            _loanAmount,
            _interestRate,
            _duration
        );

        return loanId;
    }

    function fundLoan(uint256 _loanId, address _lendingToken) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.Loan storage loan = ds.loans[_loanId];

        if (loan.isActive) revert LoanAlreadyFunded();
        if (loan.isRepaid) revert LoanAlreadyLiquidatedOrRepaid();
        if (loan.borrower == address(0)) revert InvalidLoan();

        IERC20 lendingToken = IERC20(_lendingToken);
        
        uint256 platformFeeAmount = (loan.loanAmount * ds.platformFee) / 10000;
        uint256 totalAmount = loan.loanAmount + platformFeeAmount;

        
        if (!lendingToken.transferFrom(msg.sender, address(this), totalAmount))
            revert TransferFailed();

        
        if (!lendingToken.transfer(ds.contractOwner, platformFeeAmount))
            revert TransferFailed();
        
       
        if (!lendingToken.transfer(loan.borrower, loan.loanAmount))
            revert TransferFailed();

        loan.lender = msg.sender;
        loan.startTime = block.timestamp;
        loan.isActive = true;

        emit LoanFunded(_loanId, msg.sender);
    }

    function calculateRepaymentAmount(uint256 _loanId) public view returns (uint256) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.Loan storage loan = ds.loans[_loanId];

        if (!loan.isActive) revert LoanNotActive();

        uint256 timeElapsed = block.timestamp - loan.startTime;
        uint256 interest = (loan.loanAmount * loan.interestRate * timeElapsed) /
            (365 days * 10000);
            
        return loan.loanAmount + interest;
    }

    function repayLoan(uint256 _loanId, address _lendingToken) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.Loan storage loan = ds.loans[_loanId];

        if (!loan.isActive) revert LoanNotActive();
        if (loan.isRepaid) revert LoanAlreadyLiquidatedOrRepaid();
        if (loan.borrower != msg.sender) revert NotBorrower();

        uint256 repaymentAmount = calculateRepaymentAmount(_loanId);
        IERC20 lendingToken = IERC20(_lendingToken);

        if (!lendingToken.transferFrom(msg.sender, loan.lender, repaymentAmount))
            revert TransferFailed();

        
        IERC721(loan.nftContract).transferFrom(
            address(this),
            loan.borrower,
            loan.tokenId
        );

        loan.isActive = false;
        loan.isRepaid = true;
        
        emit LoanRepaid(_loanId);
    }

    function liquidateLoan(uint256 _loanId) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.Loan storage loan = ds.loans[_loanId];

        if (!loan.isActive) revert LoanNotActive();
        if (loan.isRepaid) revert LoanAlreadyLiquidatedOrRepaid();
        if (loan.lender != msg.sender) revert NotLender();
        if (block.timestamp <= loan.startTime + loan.duration) 
            revert LoanNotExpired();

        
        IERC721(loan.nftContract).transferFrom(
            address(this),
            loan.lender,
            loan.tokenId
        );

        loan.isActive = false;
        loan.isRepaid = true;

        emit LoanLiquidated(_loanId);
    }

  
    function setPlatformFee(uint256 _newFee) external {
        LibDiamond.enforceIsContractOwner();
        if (_newFee > 1000) revert FeeTooHigh(); // Max 10%
        
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.platformFee = _newFee;
        
        emit PlatformFeeUpdated(_newFee);
    }

    function setDurationLimits(uint256 _minDuration, uint256 _maxDuration) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        
        ds.min_duration = _minDuration;
        ds.max_duration = _maxDuration;
        
        emit DurationLimitsUpdated(_minDuration, _maxDuration);
    }

   
    function getLoan(uint256 _loanId) external view returns (
        address borrower,
        address lender,
        address nftContract,
        uint256 tokenId,
        uint256 loanAmount,
        uint256 interestRate,
        uint256 startTime,
        uint256 duration,
        bool isActive,
        bool isRepaid
    ) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.Loan storage loan = ds.loans[_loanId];
        
        return (
            loan.borrower,
            loan.lender,
            loan.nftContract,
            loan.tokenId,
            loan.loanAmount,
            loan.interestRate,
            loan.startTime,
            loan.duration,
            loan.isActive,
            loan.isRepaid
        );
    }

    function getPlatformFee() external view returns (uint256) {
        return LibDiamond.diamondStorage().platformFee;
    }

    function getDurationLimits() external view returns (uint256 minDuration, uint256 maxDuration) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return (ds.min_duration, ds.max_duration);
    }
}