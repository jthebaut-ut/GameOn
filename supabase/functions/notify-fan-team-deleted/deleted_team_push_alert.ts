/**
 * Authoritative APNs alert copy for owner-driven Team deletion.
 * Critical lifecycle: not a personal "removed from Team" membership action.
 */
export function buildDeletedTeamAlert(teamName: string): { title: string; body: string } {
  const name = teamName.trim()
  return {
    title: "Team deleted",
    body: name.length > 0
      ? `Team ${name} was deleted by the Team owner.`
      : "Team was deleted by the Team owner.",
  }
}
