const { bigExp } = require('@aragon/contract-helpers-test')

const pct = x => bigExp(x, 16)

const getVoteState = async (voting, id) => {
  const { startDate, snapshotBlock, supportRequired, minAcceptQuorum, voteOverruleWindow, earlyExecution,
    yea, nay, votingPower, script, actionId, pausedAtBlock, pauseDurationBlocks, voteStatus
  } = await voting.getVote(id)

  const open = await voting.isVoteOpen(id)

  return { isOpen: open, startDate, snapshotBlock, support: supportRequired, quorum: minAcceptQuorum,
    overruleWindow: voteOverruleWindow, earlyExecution, yeas: yea, nays: nay, votingPower, script, actionId,
    pausedAtBlock, pauseDurationBlocks, voteStatus }
}

module.exports = {
  pct,
  getVoteState
}
