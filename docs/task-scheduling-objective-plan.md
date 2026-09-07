# Task scheduling objective

Status: active

## Invariant

A run reports what it can disprove as early as the graph allows. Scheduling
serves two objectives: total duration for a run that succeeds, and time to
first verdict for one that fails. Neither is served by discarding the other,
and a scheduler that represents only the first reports its cheapest evidence
last.

## Established state

`estimatedCriticalPathPriorities` assigns every task the longest remaining
path through it:

    priorities[task] = duration(task) + max(priorities[successors])

The ready queue is sorted on that value alone, descending, with the task
identifier breaking ties. Estimates come from `TaskDurationEstimateStore`,
which keeps up to eight samples per workload and answers with their median; a
workload with no samples of its own takes the median of its lane, and a lane
with no records at all takes a fixed default.

This is correct for its stated purpose. The
[throughput optimization plan](collider-throughput-optimization-plan.md)
is complete, and nothing below asks for the makespan it established to be
given up.

## The defect

A leaf's priority is its own estimated duration, because it has no successors
to add. Cheap work therefore sorts last precisely because it is cheap, and the
tasks that are cheapest to run are frequently the ones that resolve the most
uncertainty per second.

Protected-main run 34061148632 verified `9858a62c` in 1,025.2 s of execution
across 133 tasks. The two Collider self-tests are the only `hostExclusive`
test work in the graph, they own no downstream tasks, and their
`swift.package.dependencies` prerequisites were all clean at planning time,
so nothing but priority ordered them:

| task | estimate | actual | started |
| --- | --- | --- | --- |
| `swift.package.test…c15ea713` (`collider.test.cli`) | 62.6 s | 134.3 s | +748.8 s |
| `swift.package.test…54dc1ff6` (`collider.test.engine`) | 16.6 s | 80.4 s | +930.5 s |

Both passed. Both were reachable from the first scheduling boundary. The
engine suite -- 276 tests over the package that implements the scheduler
itself -- returned its verdict at 1,011.4 s of a 1,025.2 s run, and it was
broken: it had not compiled for the length of the preceding fourteen
consecutive non-green runs, each of which stopped before reaching it.

Two properties of the estimate compound this.

An estimate that is too low lowers priority, which delays execution. The
engine suite's estimate was the median of its three retained samples,
16.6 s, against an actual 80.4 s. Two of those samples predate the target
compiling at all. A median over eight samples corrects slowly, and it corrects
downward-biased work more slowly than it delays it.

Samples are recorded only by runs that finish. `durationStore.record` is
reached after `runtime.execute` returns, and a failed task propagates out of
the task group instead, so a failing run records nothing -- not even for the
tasks within it that succeeded. Estimates are refreshed only by the runs that
had the least to teach, and stay frozen across exactly the streaks where the
graph is changing most.

## What this plan does not claim

`linux.package-storage-retention` also started at +1,011.7 s, and its lateness
is not a scheduling artifact. It claims exclusive access to both Linux package
roots and to the product store, and it collects what publication leaves
behind, so ordering it after publication is a correctness requirement. Phase 3
addresses the question it answers, not the position it holds.

## Phase 1: Record the ordering the sweep already produces

Status: complete.

Retain each executed task's ready-to-start delay beside its duration in the
run manifest, and report the tasks whose delay exceeded their own duration,
longest delay first. The engine already computed this value per task and
summed it into a run total, which is a number that cannot answer the question
for any single task; keeping it is the whole of the measurement.

The delay is recorded when the task starts rather than when it finishes, so a
run that dies mid-task still carries what it knew about the ordering. Deferral
is not by itself a defect -- a run with more ready work than lanes must defer
something -- so the report names only the tasks whose deferral cost more than
their work did.

Gate evidence: [protected-main run 34066753916](https://github.com/nucleus-os/nucleus/actions/runs/34066753916)
verified `c7117a99` and reported both Collider self-tests, ranked first and
third by delay:

    deferred tasks (5 of 54)
      waited 893.0 s, ran  69.7 s  swift.package.test…54dc1ff6
      waited 824.2 s, ran   3.3 s  linux.package-source-snapshot
      waited 655.8 s, ran 132.2 s  swift.package.test…c15ea713

Behavior tests cover both halves of the distinction the measurement exists to
draw: a task the scheduler deferred records a wait exceeding its own duration,
and a task the graph blocked records a shorter one, because it was not ready
until its dependency finished.

## Phase 2: Let a barrier take the machine while it is free

Status: complete.

Phase 1's first measurement moved this phase's target twice. Of the 73 tasks
that recorded a wait, 54 waited longer than they ran, which is not by itself
the finding: 33 are `oci` tasks contending for two container lanes, where
deferral is arithmetic rather than a decision, and the 18 `lightweight` ones
account for 161 s of waiting over 25 s of work. The disproportion is on the
exclusive lane. All three `hostExclusive` tasks were deferred, they hold the
first three positions by delay, and together they waited 2,373 s to perform
205 s of work. `linux.package-source-snapshot` is the extreme and was not
predicted: 824.2 s of waiting for 3.3 s of work.

Reading that lane moved the target again. `canSchedule` admits host-exclusive
work only when `running.isEmpty`, so it is not a lane of size one -- it is a
whole-machine barrier. That changes what deferring it costs. A barrier's own
duration is paid wherever it runs, because nothing overlaps it in any
position; the variable cost is the drain that empties the machine to raise it.
The drain is zero exactly when nothing is running, which makes an idle machine
the cheapest moment a run will ever offer for a barrier, and a run is idle at
its first scheduling boundary and rarely again.

The rule could never find that moment. It drained only when the barrier's
priority was at least that of every ready and running task, and a barrier
cheap enough to be worth an idle machine is by construction outranked by the
work it would otherwise run beside. So the cheapest moment went to work that
did not need the whole machine, and the barrier waited for a full one to
drain. All three of run 34066753916's host-exclusive tasks were ready at the
first boundary; none started before 655 s.

A ready exclusive task therefore takes an idle machine. There is no cheapness
test on it, because there is nothing to trade: the duration is position
independent, so an expensive barrier is no worse a use of an idle machine than
a cheap one, and a test on cost would reintroduce the comparison that hid the
moment. Nothing here reserves lanes or reorders the other two lanes, whose
deferral the measurement showed is not worth machinery.

No task declares its own priority. A declaration that names its urgency is a
second scheduling policy maintained by hand, and it would drift from the graph
it describes.

Gate: the first protected-main sweep carrying this schedules every ready
`hostExclusive` task before it fills other lanes, and its total execution does
not regress beyond measurement noise against run 34066753916's 1,002.5 s.

Behavior test: a cheap host-exclusive leaf that is outranked by an expensive
task owning a successor still starts first when both are ready and nothing is
running.

## Phase 3: Separate the invariant a task checks from the state it changes

Status: pending

Retention answers a question and then acts on it. The question -- whether
every generation the store must serve is one the store can serve -- is
read-only and answerable at any point in the run. The action must follow
publication. Splitting them lets the check run under Phase 2's reservation
while collection stays where correctness requires, which is the same
separation the
[build store retention plan](build-store-retention-plan.md) already made
between collection and deletion in its Phase 5.

Gate: the corruption that failed run 34053908633 -- an active cohort naming
products the store does not hold -- is reported by a task that runs before
any packaging work, and collection still runs after publication.

## Phase 4: Record what a failing run measured

Status: pending

Persist duration samples for the tasks that completed, whether or not the run
did. A task that ran to completion produced a measurement, and discarding it
because a different task failed is what freezes the estimates during the
streaks that most need them current.

Gate: a run whose last task fails records samples for every task that
succeeded before it, and a subsequent run's priorities reflect them.

## Non-goals

- Do not replace longest-remaining-path with a different single objective.
  Failure latency is a second key, not a substitute; a scheduler ordered only
  by cost would defer the work the critical path depends on.
- Do not let a task declare its own priority. Urgency that is written by hand
  is not derived from the graph and will contradict it.
- Do not reorder work whose position is a correctness constraint. Exclusive
  claims, publication order, and declared dependencies bound this plan
  absolutely.

## Risk surface

Phase 2 spends a run's first moments on work that owns the whole machine, and
the case that would make that wrong is a cold run, where a long barrier
admitted at the first boundary delays the source and toolchain work everything
else waits on. The arithmetic says the duration is paid in either position, so
moving it should be free, but only warm sweeps have exercised that and a warm
sweep does not stand in for a cold one. The Phase 2 gate is a live sweep
rather than a replay for this reason, and the cold reconstruction the CI
plan's Phase 8 already requires is where the assumption is genuinely tested.

Phase 4 widens what a failing run writes to durable state. Samples are an
estimate rather than a contract, and no artifact identity or qualification
evidence derives from them, but a run recording state after a failure is
worth naming as a change in what a failure is permitted to do.
