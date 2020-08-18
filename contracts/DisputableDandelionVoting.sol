/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

pragma solidity 0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/forwarding/IForwarderWithContext.sol";
import "@aragon/os/contracts/acl/IACLOracle.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";
import "@aragon/os/contracts/apps/disputable/DisputableAragonApp.sol";
import "@aragon/minime/contracts/MiniMeToken.sol";
import "@1hive/apps-token-manager/contracts/TokenManagerHook.sol";

// TODO: Remove msg.sender from authp when ACL is updated
// TODO: Optimize
contract DisputableDandelionVoting is IACLOracle, TokenManagerHook, IForwarderWithContext, DisputableAragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    bytes32 public constant CREATE_VOTES_ROLE = keccak256("CREATE_VOTES_ROLE");
    bytes32 public constant MODIFY_SUPPORT_ROLE = keccak256("MODIFY_SUPPORT_ROLE");
    bytes32 public constant MODIFY_QUORUM_ROLE = keccak256("MODIFY_QUORUM_ROLE");
    bytes32 public constant MODIFY_BUFFER_BLOCKS_ROLE = keccak256("MODIFY_BUFFER_BLOCKS_ROLE");
    bytes32 public constant MODIFY_EXECUTION_DELAY_ROLE = keccak256("MODIFY_EXECUTION_DELAY_ROLE");

    uint64 public constant PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18
    uint8 private constant EXECUTION_PERIOD_FALLBACK_DIVISOR = 2;

    string private constant ERROR_NO_VOTE = "DANDELION_VOTING_NO_VOTE";
    string private constant ERROR_TOKEN_NOT_CONTRACT = "DANDELION_VOTING_TOKEN_NOT_CONTRACT";
    string private constant ERROR_INIT_PCTS = "DANDELION_VOTING_INIT_PCTS";
    string private constant ERROR_INIT_SUPPORT_TOO_BIG = "DANDELION_VOTING_INIT_SUPPORT_TOO_BIG";
    string private constant ERROR_DURATION_BLOCKS_ZERO = "DANDELION_VOTING_DURATION_BLOCKS_ZERO";
    string private constant ERROR_CHANGE_SUPPORT_PCTS = "DANDELION_VOTING_CHANGE_SUPPORT_PCTS";
    string private constant ERROR_CHANGE_QUORUM_PCTS = "DANDELION_VOTING_CHANGE_QUORUM_PCTS";
    string private constant ERROR_CHANGE_SUPPORT_TOO_BIG = "DANDELION_VOTING_CHANGE_SUPP_TOO_BIG";
    string private constant ERROR_CANNOT_VOTE = "DANDELION_VOTING_CANNOT_VOTE";
    string private constant ERROR_CANNOT_EXECUTE = "DANDELION_VOTING_CANNOT_EXECUTE";
    string private constant ERROR_CANNOT_FORWARD = "DANDELION_VOTING_CANNOT_FORWARD";
    string private constant ERROR_ORACLE_SENDER_MISSING = "DANDELION_VOTING_ORACLE_SENDER_MISSING";
    string private constant ERROR_ORACLE_SENDER_TOO_BIG = "DANDELION_VOTING_ORACLE_SENDER_TOO_BIG";
    string private constant ERROR_ORACLE_SENDER_ZERO = "DANDELION_VOTING_ORACLE_SENDER_ZERO";

    enum VoterState { Absent, Yea, Nay }

    enum VoteStatus {
        Active,                         // A vote that has been reported to the Agreement
        Paused,                         // A vote that is being challenged
        Cancelled,                      // A vote that has been cancelled since it was refused after a dispute
        Executed                        // A vote that has been executed
    }

    struct Vote {
        bool executed;
        uint64 startBlock;
        uint64 executionBlock;
        uint64 snapshotBlock;
        uint64 supportRequiredPct;
        uint64 minAcceptQuorumPct;
        uint256 yea;
        uint256 nay;
        bytes executionScript;
        mapping (address => VoterState) voters;
        uint64 pausedAtBlock;                   // Block when the vote was paused
        uint64 pauseDurationBlocks;             // Duration in blocks while the vote has been paused
        VoteStatus voteStatus;      // Status of the disputable vote
        uint256 actionId;                       // Identification number of the disputable action in the context of the agreement
    }

    MiniMeToken public token;
    uint64 public supportRequiredPct;
    uint64 public minAcceptQuorumPct;
    uint64 public durationBlocks;
    uint64 public bufferBlocks;         // Blocks between each vote
    uint64 public executionDelayBlocks;

    // We are mimicing an array, we use a mapping instead to make app upgrade more graceful
    mapping (uint256 => Vote) internal votes;
    uint256 public votesLength;
    mapping (address => uint256) public latestYeaVoteId;

    event StartVote(uint256 indexed voteId, address indexed creator, bytes context);
    event CastVote(uint256 indexed voteId, address indexed voter, bool supports, uint256 stake);
    event PauseVote(uint256 indexed voteId, uint256 indexed challengeId);
    event ResumeVote(uint256 indexed voteId);
    event CancelVote(uint256 indexed voteId);
    event ExecuteVote(uint256 indexed voteId);
    event ChangeSupportRequired(uint64 supportRequiredPct);
    event ChangeMinQuorum(uint64 minAcceptQuorumPct);
    event ChangeBufferBlocks(uint64 bufferBlocks);
    event ChangeExecutionDelayBlocks(uint64 executionDelayBlocks);

    modifier voteExists(uint256 _voteId) {
        require(_voteExists(_voteId), ERROR_NO_VOTE);
        _;
    }

    /**
    * @notice Initialize Voting app with `_token.symbol(): string` for governance, minimum support of `@formatPct(_supportRequiredPct)`%, minimum acceptance quorum of `@formatPct(_minAcceptQuorumPct)`%, a voting duration of `_voteDurationBlocks` blocks, and a vote buffer of `_voteBufferBlocks` blocks
    * @param _token MiniMeToken Address that will be used as governance token
    * @param _supportRequiredPct Percentage of yeas in cast votes for a vote to succeed (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%)
    * @param _minAcceptQuorumPct Percentage of yeas in total possible votes for a vote to succeed (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%)
    * @param _durationBlocks Blocks that a vote will be open for token holders to vote
    * @param _bufferBlocks Minimum number of blocks between the start block of each vote
    * @param _executionDelayBlocks Minimum number of blocks between the end of a vote and when it can be executed
    */
    function initialize(
        MiniMeToken _token,
        uint64 _supportRequiredPct,
        uint64 _minAcceptQuorumPct,
        uint64 _durationBlocks,
        uint64 _bufferBlocks,
        uint64 _executionDelayBlocks
    )
        external onlyInit
    {
        initialized();

        require(isContract(_token), ERROR_TOKEN_NOT_CONTRACT);
        require(_minAcceptQuorumPct <= _supportRequiredPct, ERROR_INIT_PCTS);
        require(_supportRequiredPct < PCT_BASE, ERROR_INIT_SUPPORT_TOO_BIG);
        require(_durationBlocks > 0, ERROR_DURATION_BLOCKS_ZERO);

        token = _token;
        supportRequiredPct = _supportRequiredPct;
        minAcceptQuorumPct = _minAcceptQuorumPct;
        durationBlocks = _durationBlocks;
        bufferBlocks = _bufferBlocks;
        executionDelayBlocks = _executionDelayBlocks;
    }

    /**
    * @notice Change required support to `@formatPct(_supportRequiredPct)`%
    * @param _supportRequiredPct New required support
    */
    function changeSupportRequiredPct(uint64 _supportRequiredPct)
        external authP(MODIFY_SUPPORT_ROLE, arr(uint256(_supportRequiredPct), uint256(supportRequiredPct)))
    {
        require(minAcceptQuorumPct <= _supportRequiredPct, ERROR_CHANGE_SUPPORT_PCTS);
        require(_supportRequiredPct < PCT_BASE, ERROR_CHANGE_SUPPORT_TOO_BIG);
        supportRequiredPct = _supportRequiredPct;

        emit ChangeSupportRequired(_supportRequiredPct);
    }

    /**
    * @notice Change minimum acceptance quorum to `@formatPct(_minAcceptQuorumPct)`%
    * @param _minAcceptQuorumPct New acceptance quorum
    */
    function changeMinAcceptQuorumPct(uint64 _minAcceptQuorumPct)
        external authP(MODIFY_QUORUM_ROLE, arr(uint256(_minAcceptQuorumPct), uint256(minAcceptQuorumPct)))
    {
        require(_minAcceptQuorumPct <= supportRequiredPct, ERROR_CHANGE_QUORUM_PCTS);
        minAcceptQuorumPct = _minAcceptQuorumPct;

        emit ChangeMinQuorum(_minAcceptQuorumPct);
    }

    /**
    * @notice Change vote buffer to `_voteBufferBlocks` blocks
    * @param _bufferBlocks New vote buffer defined in blocks
    */
    function changeBufferBlocks(uint64 _bufferBlocks) external auth(MODIFY_BUFFER_BLOCKS_ROLE) {
        bufferBlocks = _bufferBlocks;
        emit ChangeBufferBlocks(_bufferBlocks);
    }

    /**
    * @notice Change execution delay to `_executionDelayBlocks` blocks
    * @param _executionDelayBlocks New vote execution delay defined in blocks
    */
    function changeExecutionDelayBlocks(uint64 _executionDelayBlocks) external auth(MODIFY_EXECUTION_DELAY_ROLE) {
        executionDelayBlocks = _executionDelayBlocks;
        emit ChangeExecutionDelayBlocks(_executionDelayBlocks);
    }

    /**
    * @notice Create a new vote about "`_context`"
    * @param _executionScript EVM script to be executed on approval
    * @param _context Vote metadata
    * @param _castVote Whether to also cast newly created vote
    * @return voteId id for newly created vote
    */
    function newVote(bytes _executionScript, bytes _context, bool _castVote)
        external authP(CREATE_VOTES_ROLE, arr(msg.sender)) returns (uint256 voteId)
    {
        return _newVote(_executionScript, _context, _castVote);
    }

    /**
    * @notice Vote `_supports ? 'yes' : 'no'` in vote #`_voteId`
    * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
    *      created via `newVote(),` which requires initialization
    * @param _voteId Id for vote
    * @param _supports Whether voter supports the vote
    */
    function vote(uint256 _voteId, bool _supports) external voteExists(_voteId) {
        require(_canVote(votes[_voteId], msg.sender), ERROR_CANNOT_VOTE);
        _vote(_voteId, _supports, msg.sender);
    }

    /**
    * @notice Execute vote #`_voteId`
    * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
    *      created via `newVote(),` which requires initialization
    * @param _voteId Id for vote
    */
    function executeVote(uint256 _voteId) external voteExists(_voteId) {
        Vote storage vote_ = votes[_voteId];
        require(_canExecute(vote_), ERROR_CANNOT_EXECUTE);

        vote_.executed = true;
        vote_.voteStatus = VoteStatus.Executed;
        _closeAgreementAction(vote_.actionId);

        bytes memory input = new bytes(0); // TODO: Consider input for voting scripts
        address[] memory blacklist = new address[](1);
        blacklist[0] = address(_getAgreement());
        runScript(vote_.executionScript, input, blacklist);
        emit ExecuteVote(_voteId);
    }

    // Getter fns

    /**
    * @notice Tells whether a vote #`_voteId` can be executed or not
    * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
    *      created via `newVote(),` which requires initialization
    * @return True if the given vote can be executed, false otherwise
    */
    function canExecute(uint256 _voteId) external view voteExists(_voteId) returns (bool) {
        return _canExecute(votes[_voteId]);
    }

    /**
    * @notice Tells whether `_sender` can participate in the vote #`_voteId` or not
    * @dev Initialization check is implicitly provided by `voteExists()` as new votes can only be
    *      created via `newVote(),` which requires initialization
    * @return True if the given voter can participate a certain vote, false otherwise
    */
    function canVote(uint256 _voteId, address _voter) external view voteExists(_voteId) returns (bool) {
        return _canVote(votes[_voteId], _voter);
    }

    /**
    * @dev Return all information for a vote by its ID
    * @param _voteId Vote identifier
    * @return Vote open status
    * @return Vote executed status
    * @return Vote start block
    * @return Vote snapshot block
    * @return Vote support required
    * @return Vote minimum acceptance quorum
    * @return Vote yeas amount
    * @return Vote nays amount
    * @return Vote power
    * @return Vote script
    */
    function getVote(uint256 _voteId) external view voteExists(_voteId)
        returns (
            bool open,
            bool executed,
            uint64 startBlock,
            uint64 executionBlock,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 votingPower,
            uint256 yea,
            uint256 nay,
            bytes script
        )
    {
        Vote storage vote_ = votes[_voteId];

        open = _isVoteOpen(vote_);
        executed = vote_.executed;
        startBlock = vote_.startBlock;
        executionBlock = vote_.executionBlock;
        snapshotBlock = vote_.snapshotBlock;
        votingPower = token.totalSupplyAt(vote_.snapshotBlock);
        supportRequired = vote_.supportRequiredPct;
        minAcceptQuorum = vote_.minAcceptQuorumPct;
        yea = vote_.yea;
        nay = vote_.nay;
        script = vote_.executionScript;
    }

    function getDisputableInfo(uint256 _voteId) external view voteExists(_voteId)
        returns (
            uint256 actionId,
            uint64 pausedAtBlock,
            uint64 pauseDurationBlocks,
            VoteStatus status
        )
    {
        Vote storage vote_ = votes[_voteId];
        actionId = vote_.actionId;
        pausedAtBlock = vote_.pausedAtBlock;
        pauseDurationBlocks = vote_.pauseDurationBlocks;
        status = vote_.voteStatus;
    }

    /**
    * @dev Return the state of a voter for a given vote by its ID
    * @param _voteId Vote identifier
    * @return VoterState of the requested voter for a certain vote
    */
    function getVoterState(uint256 _voteId, address _voter) external view voteExists(_voteId) returns (VoterState) {
        return votes[_voteId].voters[_voter];
    }

    // Disputable getter fns

    /**
    * @dev Tells whether a vote can be challenged or not
    * @return True if the given vote can be challenged, false otherwise
    */
    function canChallenge(uint256 _voteId) external view returns (bool) {
        return _voteExists(_voteId) && _canPause(votes[_voteId]);
    }

    /**
    * @dev Tells whether a vote can be closed or not
    * @return True if the given vote can be closed, false otherwise
    */
    function canClose(uint256 _voteId) external view returns (bool) {
        Vote storage vote_ = votes[_voteId];
        VoteStatus voteStatus = vote_.voteStatus;
        return _voteExists(_voteId) && !_isVoteOpen(vote_)
            && (voteStatus == VoteStatus.Active || voteStatus == VoteStatus.Executed);
    }

    // Forwarding fns

    /**
    * @notice Creates a vote to execute the desired action, and casts a support vote if possible
    * @dev IForwarderWithContext interface conformance
           Disputable apps are required to be the initial step in the forwarding chain
    * @param _evmScript EVM script to be executed on approval
    * @param _context Vote context
    */
    function forward(bytes _evmScript, bytes _context) external {
        require(this.canForward(msg.sender, _evmScript), ERROR_CANNOT_FORWARD);
        _newVote(_evmScript, _context, true);
    }

    /**
    * @dev Returns whether `_sender` can forward actions
    * @dev IForwarderWithContext interface conformance
    * @param _sender Address of the account intending to forward an action
    * @param _evmScript EVM script being forwarded
    * @return True if the given address can create votes
    */
    // TODO: Cross check with disputable voting
    function canForward(address _sender, bytes _evmScript) external view returns (bool) {
        // TODO: Handle the case where a Disputable app doesn't have an Agreement set
        // Note that `canPerform()` implicitly does an initialization check itself
        return canPerform(_sender, CREATE_VOTES_ROLE, arr(_sender));
    }

    // ACL Oracle fns

    /**
    * @dev IACLOracle interface conformance. The ACLOracle permissioned function should specify the sender
    *      with 'authP(SOME_ACL_ROLE, arr(sender))', where sender is typically set to 'msg.sender'.
    * @param _how Array passed by Kernel when using 'authP()'. First item should be the address to check can perform.
    * return False if the sender has voted on the most recent open vote or closed unexecuted vote, true if they haven't.
    */
    function canPerform(address, address, bytes32, uint256[] _how) external view returns (bool) {
        require(_how.length > 0, ERROR_ORACLE_SENDER_MISSING);
        require(_how[0] < 2**160, ERROR_ORACLE_SENDER_TOO_BIG);
        require(_how[0] != 0, ERROR_ORACLE_SENDER_ZERO);

        return _noRecentPositiveVotes(address(_how[0]));
    }

    // Token Manager Hook fns

    /**
    * @dev TokenManagerHook interface conformance.
    * @param _from The address from which funds will be transferred
    * return False if `_from` has voted on the most recent open vote or closed unexecuted vote, true if they haven't.
    */
    function _onTransfer(address _from, address _to, uint256 _amount) internal returns (bool) {
        return _noRecentPositiveVotes(_from);
    }

    // IDisputable fns

    /**
    * @dev Challenge a vote. Note that this can only be called if DisputableDandelionVoting.canChallenge() returns true
    * @param _voteId Identification number of the vote to be challenged
    * @param _challengeId Identification number of the challenge associated to the vote in the Agreement app
    */
    function _onDisputableActionChallenged(uint256 _voteId, uint256 _challengeId, address /* _challenger */) internal {
        Vote storage vote_ = votes[_voteId];

        vote_.voteStatus = VoteStatus.Paused;
        vote_.pausedAtBlock = getBlockNumber64();

        emit PauseVote(_voteId, _challengeId);
    }

    /**
    * @dev Allow a vote. Note that either this, _onDisputableActionRejected() or _onDisputableActionVoided()
    *      will be called once for each challenge
    * @param _voteId Identification number of the vote to be allowed
    */
    function _onDisputableActionAllowed(uint256 _voteId) internal {
        Vote storage vote_ = votes[_voteId];

        vote_.voteStatus = VoteStatus.Active;
        vote_.pauseDurationBlocks = getBlockNumber64().sub(vote_.pausedAtBlock);

        emit ResumeVote(_voteId);
    }

    /**
    * @dev Reject a vote. Note that either this, _onDisputableActionAllowed() or _onDisputableActionVoided()
    *      will be called once for each challenge
    * @param _voteId Identification number of the vote to be rejected
    */
    function _onDisputableActionRejected(uint256 _voteId) internal {
        Vote storage vote_ = votes[_voteId];

        vote_.voteStatus = VoteStatus.Cancelled;
        vote_.pauseDurationBlocks = getBlockNumber64().sub(vote_.pausedAtBlock);

        emit CancelVote(_voteId);
    }

    /**
    * @dev Void an entry. Note that either this, _onDisputableActionAllowed() or _onDisputableActionRejected()
    *      will be called once for each challenge
    * @param _voteId Identification number of the entry to be voided
    */
    function _onDisputableActionVoided(uint256 _voteId) internal {
        // When a challenged vote is voided, it is considered as being allowed.
        // This could be the case for challenges where the arbitrator refuses to rule.
        _onDisputableActionAllowed(_voteId);
    }

    // Internal fns

    /**
    * @dev Internal function to create a new vote
    * @return voteId id for newly created vote
    */
    function _newVote(bytes _executionScript, bytes _context, bool _castVote) internal returns (uint256 voteId) {
        voteId = ++votesLength; // Increment votesLength before assigning to votedId. The first voteId is 1.

        uint64 previousVoteStartBlock = votes[voteId - 1].startBlock;
        uint64 earliestStartBlock = previousVoteStartBlock == 0 ? 0 : previousVoteStartBlock.add(bufferBlocks);
        uint64 startBlock = earliestStartBlock < getBlockNumber64() ? getBlockNumber64() : earliestStartBlock;

        uint64 executionBlock = startBlock.add(durationBlocks).add(executionDelayBlocks);

        Vote storage vote_ = votes[voteId];
        vote_.startBlock = startBlock;
        vote_.executionBlock = executionBlock;
        vote_.snapshotBlock = startBlock - 1; // avoid double voting in this very block
        vote_.supportRequiredPct = supportRequiredPct;
        vote_.minAcceptQuorumPct = minAcceptQuorumPct;
        vote_.executionScript = _executionScript;
        vote_.voteStatus = VoteStatus.Active;

        // Notify the Agreement app tied to the current voting app about the vote created.
        // This is mandatory to make the vote disputable, by storing a reference to it on the Agreement app.
        vote_.actionId = _newAgreementAction(voteId, _context, msg.sender);

        emit StartVote(voteId, msg.sender, _context);

        if (_castVote && _canVote(vote_, msg.sender)) {
            _vote(voteId, true, msg.sender);
        }
    }

    /**
    * @dev Internal function to cast a vote. It assumes the queried vote exists.
    */
    function _vote(uint256 _voteId, bool _supports, address _voter) internal {
        Vote storage vote_ = votes[_voteId];

        uint256 voterStake = _voterStake(vote_, _voter);

        if (_supports) {
            vote_.yea = vote_.yea.add(voterStake);
            if (latestYeaVoteId[_voter] < _voteId) {
                latestYeaVoteId[_voter] = _voteId;
            }
        } else {
            vote_.nay = vote_.nay.add(voterStake);
        }

        vote_.voters[_voter] = _supports ? VoterState.Yea : VoterState.Nay;

        emit CastVote(_voteId, _voter, _supports, voterStake);
    }

    /**
    * @dev Internal function to check if a vote can be executed. It assumes the queried vote exists.
    * @return True if the given vote can be executed, false otherwise
    */
    function _canExecute(Vote storage vote_) internal view returns (bool) {
        if (vote_.executed) {
            return false;
        }

        if (_isVoteOpen(vote_)) {
            return false;
        }

        if (getBlockNumber64() < _voteExecutionBlock(vote_)) {
            return false;
        }

        if (vote_.voteStatus != VoteStatus.Active) {
            return false;
        }

        return _votePassed(vote_);
    }

    /**
    * @dev Internal function to check if a vote has passed. It assumes the vote period has passed.
    * @return True if the given vote has passed, false otherwise.
    */
    function _votePassed(Vote storage vote_) internal view returns (bool) {
        uint256 totalVotes = vote_.yea.add(vote_.nay);
        uint256 votingPowerAtSnapshot = token.totalSupplyAt(vote_.snapshotBlock);

        bool hasSupportRequired = _isValuePct(vote_.yea, totalVotes, vote_.supportRequiredPct);
        bool hasMinQuorum = _isValuePct(vote_.yea, votingPowerAtSnapshot, vote_.minAcceptQuorumPct);
        bool notCancelled = vote_.voteStatus != VoteStatus.Cancelled;

        return hasSupportRequired && hasMinQuorum && notCancelled;
    }

    /**
    * @dev Internal function to check if a voter can participate on a vote. It assumes the queried vote exists.
    * @return True if the given voter can participate a certain vote, false otherwise
    */
    function _canVote(Vote storage vote_, address _voter) internal view returns (bool) {
        uint256 voterStake = _voterStake(vote_, _voter);
        bool hasNotVoted = vote_.voters[_voter] == VoterState.Absent;

        return _isVoteOpen(vote_) && voterStake > 0 && hasNotVoted;
    }

    /**
    * @dev Tell whether a vote can be paused or not
    * @param vote_ Vote action instance being queried
    * @return True if the given vote can be paused, false otherwise
    */
    function _canPause(Vote storage vote_) internal view returns (bool) {
        return vote_.voteStatus == VoteStatus.Active && vote_.pausedAtBlock == 0;
    }

    /**
    * @dev Internal function to determine a voters stake which is the minimum of snapshot balance and current balance.
    * @return Voters current stake.
    */
    function _voterStake(Vote storage vote_, address _voter) internal view returns (uint256) {
        uint256 balanceAtSnapshot = token.balanceOfAt(_voter, vote_.snapshotBlock);
        uint256 currentBalance = token.balanceOf(_voter);

        return balanceAtSnapshot < currentBalance ? balanceAtSnapshot : currentBalance;
    }

    /**
    * @dev Internal function to check if a vote is still open
    * @return True if the given vote is open, false otherwise
    */
    function _isVoteOpen(Vote storage vote_) internal view returns (bool) {
        uint256 votingPowerAtSnapshot = token.totalSupplyAt(vote_.snapshotBlock);
        return votingPowerAtSnapshot > 0
            && vote_.voteStatus == VoteStatus.Active
            && getBlockNumber64() >= vote_.startBlock
            && getBlockNumber64() < _voteEndBlock(vote_);
    }

    /**
    * @dev Internal function to calculate the end block of a vote. It assumes the queried vote exists
           and the vote is not paused or cancelled by Agreements.
    */
    function _voteEndBlock(Vote storage vote_) internal view returns (uint64) {
        uint64 endBlock = vote_.startBlock.add(durationBlocks);
        return endBlock.add(vote_.pauseDurationBlocks);
    }

    /**
    * @dev Internal function to calculate the execution block of a vote. It assumes the queried vote exists
    *      and the vote is not paused or cancelled.
    */
    function _voteExecutionBlock(Vote storage vote_) internal view returns (uint64) {
        return vote_.executionBlock.add(vote_.pauseDurationBlocks);
    }

    /**
    * @dev Internal function to check if a certain vote id exists
    * @return True if the given vote id was already registered, false otherwise
    */
    function _voteExists(uint256 _voteId) internal view returns (bool) {
        return _voteId != 0 && _voteId <= votesLength;
    }

    /**
    * @dev Calculates whether `_value` is more than a percentage `_pct` of `_total`
    */
    function _isValuePct(uint256 _value, uint256 _total, uint256 _pct) internal pure returns (bool) {
        if (_total == 0) {
            return false;
        }

        uint256 computedPct = _value.mul(PCT_BASE) / _total;
        return computedPct > _pct;
    }

    /**
    * @notice Returns whether the sender has voted in favour of the most recent open vote or closed unexecuted/uncancelled vote.
    * @param _sender Voter to check if they can vote
    * return False if the sender has voted on the most recent open vote or closed unexecuted/uncancelled vote, true if they haven't.
    */
    function _noRecentPositiveVotes(address _sender) internal view returns (bool) {
        if (votesLength == 0) {
            return true;
        }

        uint256 senderLatestYeaVoteId = latestYeaVoteId[_sender];
        Vote storage senderLatestYeaVote_ = votes[senderLatestYeaVoteId];
        uint256 voteExecutionBlock = _voteExecutionBlock(senderLatestYeaVote_);

        bool senderLatestYeaVoteFailed = !_votePassed(senderLatestYeaVote_);
        bool senderLatestYeaVoteNotPaused = senderLatestYeaVote_.voteStatus != VoteStatus.Paused;
        bool senderLatestYeaVoteExecutionBlockPassed = getBlockNumber64() >= voteExecutionBlock;

        uint64 fallbackPeriodLength = bufferBlocks / EXECUTION_PERIOD_FALLBACK_DIVISOR;
        bool senderLatestYeaVoteFallbackPeriodPassed = getBlockNumber64() > voteExecutionBlock.add(fallbackPeriodLength);

        return senderLatestYeaVoteNotPaused && senderLatestYeaVoteFailed && senderLatestYeaVoteExecutionBlockPassed
            || senderLatestYeaVoteNotPaused && senderLatestYeaVoteFallbackPeriodPassed
            || senderLatestYeaVote_.executed;
    }
}
