const { bigExp } = require('@aragon/contract-helpers-test')

const pct = x => bigExp(x, 16)

const getVoteState = async (voting, id) => {
  const { open, executed, startDate, snapshotBlock, supportRequired, minAcceptQuorum, voteOverruleWindow, earlyExecution, yea, nay, votingPower, script } = await voting.getVote(id)
  return { isOpen: open, isExecuted: executed, startDate, snapshotBlock, support: supportRequired, quorum: minAcceptQuorum, overruleWindow: voteOverruleWindow, earlyExecution, yeas: yea, nays: nay, votingPower, script }
}

module.exports = {
  pct,
  getVoteState
}
