# Pachyderm - an elephant never forgets

**Immortal actors for many machines.**

```elixir
defmodule MyApp.Counter do
  use Pachyderm.Entity

  def init(_entity_id), do: 0
  def activate(_message, state), do: {[], state + 1}
end
```

- Both `init/1` and `activate/2` are callbacks of the `Pachyderm.Entity`
- `init/1` is optional, default implementation returns `nil`.
- `activate/2` must always return a two tuple.
  The first element being a list of `{address, message}` to send and the second being the updated state.
- The address of an entity is always `{module, term}`.

```elixir
$ iex -S mix

iex> alias Pachyderm.Ecosystems.LocalDisk
# Pachyderm.Ecosystems.LocalDisk
iex> counter = {MyApp.Counter, "my_counter"}
# {MyApp.Counter, "my_counter"}

iex> LocalDisk.send_sync(counter, :increment)
# {:ok, 1}
iex> LocalDisk.send_sync(counter, :increment)
# {:ok, 2}

iex> LocalDisk.follow(counter)
# {:ok, 2}
iex> LocalDisk.send_sync(counter, :increment)
# {:ok, 3}

iex> flush()
# {{MyApp.Counter, "my_counter"}, 3}
# :ok
```

*NOTE: if you retry this example in a new iex session the counter will remember previous state.*

## Message passing example

```elixir
defmodule MyApp.PingPong do
  use Pachyderm.Entity

  def activate({:ping, client}, nil), do: {[{client, :pong}], :pinged}
  def activate(:pong, nil), do: {[], :ponged}
end
```

```elixir
iex> alias Pachyderm.Ecosystems.LocalDisk
# Pachyderm.Ecosystems.LocalDisk
iex> alice = {MyApp.PingPong, "alice"}
# {MyApp.PingPong, "alice"}
iex> bob = {MyApp.PingPong, "bob"}
# {MyApp.PingPong, "bob"}

iex> LocalDisk.follow(alice)
# {:ok, nil}
iex> LocalDisk.follow(bob)
# {:ok, nil}

# Alice pings Bob
iex> LocalDisk.send_sync(bob, {:ping, alice})
# {:ok, :pinged}

iex> flush()
# {{MyApp.PingPong, "bob"}, :pinged}
# {{MyApp.PingPong, "alice"}, :ponged}
# :ok
```

TODO add warning if code calls `send`/`send_sync` within an activate callback.

## Ecosystems

An ecosystem is a collection of entities an the environment they are executing in.
An application would be expect to be running only one ecosystem.

Ecosystems are isolated from one another.
Starting multiple ecosystems is mostly used for testing.

```elixir
setup %{} do
  ecosystem = LocalDisk.participate(random_string())
  {:ok, ecosystem: ecosystem}
end

test "state is preserved between activations", %{ecosystem: ecosystem} do
  id = {Counter, "my_counter"}
  assert {:ok, 1} = LocalDisk.send_sync(id, :increment, ecosystem)
  assert {:ok, 2} = LocalDisk.send_sync(id, :increment, ecosystem)
end
```

The `LocalDisk` ecosystem is for development purposes and works for a single node only.
Use this ecosystem for development purposes without requiring any further dependencies.

Entity state is preserved to disk and so survives restarts.
This is useful for checking the behaviour of updated code using old saved entity states.

See the roadmap for progress on multi-node ecosystems,
one uses the database to guarantee consistency and one native to an erlang cluster.

## PgBacked ecosystem

This ecosystem ensures only a single worker is running for any entity accross multiple machines by use of `:global` and [pg_advisory_lock](https://www.postgresql.org/docs/9.4/static/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS)

1.

##### Notes

- It's possible to start more than one supervisor/registry/pg session for each ecosystem.
  pg_advisory_lock ensures uniqueness between machines.
  global ensures uniqueness on machines.
- For efficient lookup of processes a client needs ecosystem_id (to pass to global) and register pid to start a new process
- A separate register process is needed (instead of letting a worker take their own locks) as this process is responsible for setting up a monitor to release the pg_advisory_lock.
- If the pg_session dies all locks are lost and so all workers must die, This does not need to be true if all writes go through the same session.
- The desire to start a new registry process and session for each ecosystem might be unwise.
  A single pg_session could be used by several registries.
  A single registry could use several pg_sessions although it would need to remember which lock was on which session to release it.
  This could have a race condition where a lock needs to be released but a write goes through another session so would need to guarantee that the session with the lock is used for the write.
  You can write a query that takes lock j equalling entity id but might be slow

# Roadmap

### System simulation and property testing

This part of the project already includes the ability to apply a series of events to a simulated ecosystem by using `Pachyderm.Ecosystems.Simulation.run/2`.
There is also an `exhaust` function that will exhaustivly explore every possible ordering of message delivery.
This can be used to see if a system is deterministict under reordering.

- [ ] When an activation errors, show the list of all messages received by that entity using `__STACKTRACE__`
  This should be implemented to look like the "message received" code that exists in GenServer.
- [ ] Add a maximum message depth to the run of the simulation.
- [ ] Add a `Cohort` module that is responsible for running parrallel instances of an ecosystem.
  This should replace the `exhaust` function.
- [ ] Use a stream generator to explore the space of possible message orderings.
- TCP is a great example case for exploring.
  Explain what calm is.
  with just a server you can check message reordering.
  with dropped messages you can show output is always a subset of the full output.
  with duplicated messages you can show full calm.
  duplicates can be achieved by just putting messages in twice.
- [ ] Be able to switch out module implementations for test purposes.
- Have `activating` work the same as all other ecosystems, i.e. functions take a reference and state is implicitly updated.
  This can be achieved by putting the working state in an Agent, this can be supervised by the `:pachyderm_simulated` app

### At least once message delivery for `LocalDisk`

The LocalDisk ecosystem of entities has at most once message delivery.
It uses casts to send all outgoing messages after executing each iteration of the entity.

Instead it could do the following steps

1. save state and messages to dets.
2. return to caller using `GenServer.reply(from, {:ok, state})`.
3. Use `GenServer.call` to send messages to entities.
4. save state and empty list of messages to dets.
5. On startup the worker should check the list of outbound is empty before accepting new messages.
6. The state of the worker should be transient so it is restarted after crash to resend messages, but shutting down after a timeout will close the process.

**Question:** what if after all this effort the receiver crashes while processing the message.
Does that count as a delivery?
Would the system retry forever?

### Discussion of software updates

Saving structs to disk will leave them in the old format.
There should be a version key that can be used to upgrade

### Single node deploy on digital ocean or some such

I suggest the rock paper scissors implementation

### Runtime Deadletter queue

For those cases the simulator did not catch

### Typed Actors (entities)

I can see several ways to make typed actors a reality in this model.
It is easier because of the reduced scope of what an actor can do.
However erlang/Elixir code can always do more than a function spec indicates,
however I am happy with the responsibility of writing pure `activate` functions to rest with the users of this library.

1. This could be done my making the envelopes, combination of address and message, an opaque type.
  If each entity module is the only place that can make this opaque type.
  e.g. `Counter.post(counter_id, :increment)`.
  Then dialyzer can be used to check that all envlopes are valid, and within Pachyderm envelopes are the only way to cause side effects.

2. By leaning on the Elixir macrosystem, an ecosystem can be built that defines all of the actor types it has.
  e.g. `use Pachyderm.Ecosystem.InMemory, [Counter]`.
  At this point we can require every Entity type to also export types for `id` and `message`.

  NOTE: there is an error in dialyzer, which requires adding specs to the post function.
  Dialyzer does not support multi headed function specs.

  ```elixir
  def foo(:a, :b), do: :ok
  def foo(:x, :y), do: :ok

  # derived spec
  @spec foo(:a | :x, b: :y) :: :ok

  # correct spec
  @spec foo(:a, b:) :: :ok
  @spec foo(:x, y:) :: :ok
  ```

3. Decouple the concepts of entity type and address type.
  Entities should be able to post and address that gives recipients only a subset of message types to send.

4. Add a function to type the id's of each kind of entity.
  This can have a default implementation of `def id(str), do: {__MODULE__, str}`

### Event sourced entities

With the simple model, the whole state is returned which means it is not possible to control what updates a follower sees.
I want to investigate event sourcing each entity.

This appears to be a lower level of abstraction,
i.e. it is always possible to model a state based system by using a single event of type entity_updated.

### DbBacked ecosystem

I think this is a good way to prototype multi-node

By using `:global` + locks on the DB, uniqueness of activations can be guaranteed across nodes.
Steps to running an activation.

1. See if the entity is already running in `:global`.
2. Take out advisory lock for entity, if this fails retry search in global.
3. Register new instantiation of entity in `:global`.

https://github.com/elixir-ecto/ecto/blob/master/integration_test/pg/deadlock_test.exs

### Events and DB

This is even easier to resolve conflicts, it is also the closest to the current system I am running.

Would need and events table

- id, monotonic db created helpful to read the whole table
- type, e.g. user_signed_up might want to split to entity type and event type
- event_version, used to update versions.
- entity_id, entity ids are unique across all kinds not a hard requirement but easier for filtering
- event_count, unique in combination with entity_id
- transaction_count(command_id), groups events that were committed in the same step, should reference command
- payload, i think safest to just have this as a binary for kafka compatibility

commands table, join with events for a single transaction.
This table should have a processed true of false flag, this can leave commands in the Deadletter queue.

uniqueness between entity and transaction_id(interaction_id) gives security against conflicts.
advisory locks are not necessary but improve efficiency when running background task to complete commands that where not executed in normal flow.

Advisory locks are necessary if in memory state is going to be used in queries.
If not process running on one machine can miss updates on the table.
Even trailing the DB changelog can still have a situation where a client sends message to node a and the reads node b process before it has updated.
The whole point of this system is to not have eventual consistency.

This is a memory image, and would work very nicely.

Memory image can be augmented by having a command table. would need hooks in the apply event step.
Needs entity timeouts but that should be everything. can use ets for image but if entity crashes should be built from zero state
snapshotting is a different process.

Events should implement the event type. need to turn struct to Ecto record thing.
Would be great if could use in memory localnode thing for development.
Examples should definetly include update from previous version.
If smart can use the same code to read command from request body as command payload.

api-version is not the same as entity_version, maybe table should be system/schema_version.
That would mean clients could send api_version which matched db.
Also possible to have command version.
Also because events are committed it's not required to be able to read old commands from db to current Struct.

Make project called monies with stripe demo.

### InMemory distributed erlang

For this to work there needs to be a guarantee that nodes will all agree the order of messages received at each entity.
As long as this is true it is not even that important for at least/most once delivery.
I think the most useful semantics are at least once because idempotency can be added to activations.

This backend will need to implement some consensus protocol.
I do not think it can be standard Raft because I don't want an entity to be frozen after failing to handle a message.

There were some further questions about raft here https://elixirforum.com/t/questions-about-raft/14634
Raft does have the nice feature that a node discovering it is often nearer a client could start a leader election for itself.

The throughput of the consensus mechanism is not important.
System throughput is increased by having lots of statemachines that can run in parrallel.
Reducing latency is a desirable feature. 1 round trip is possible if a node has already done some prework to get permission to write.

In some cases. i.e. when confirming linearizability of messages from a client,
it would be desirable to have a system that worked very fast in the case of no contention
but then took much longer to resolve conflicts the assumption being conflict resolution is just a way to block bad actors.

It would also be acceptable to have a system that froze in node downs as long as it never conflicted.

I want to avoid running leaders because an entity might remain dormant for a substantial period,
therefore pinging the leader would be a wast of resources.
It might be possible to batch leadership. i.e. node a is the leader for all entities a-f.

Raft implementation https://github.com/cdegroot/palapa/tree/master/erix

Talk about wooga/locker
https://www.youtube.com/watch?v=ekcBAseo7Js

https://github.com/edwardbadboy/paxosd

##### A hundred impossibility proofs for distributed computing
http://www.dtic.mil/dtic/tr/fulltext/u2/a216391.pdf

#### Actor database
http://rcardin.github.io/database/actor-model/reactive/akka/scala/2016/02/07/actorbase-or-the-persistence-chaos.html
https://arxiv.org/pdf/1707.06507.pdf

##### Paxos

- This seamed a reasonably good into to single value paxos https://www.youtube.com/watch?v=d7nAGI_NZPk
- Some other algorithms to check here https://www.youtube.com/watch?v=XUQJvMALfUA
- Paxos made simple https://www.idi.ntnu.no/emner/tdt02/PaxosMadeSimple.pdf

Further resources

- Just Say NO to Paxos Overhead: Replacing Consensus with Network Ordering https://syslab.cs.washington.edu/papers/nopaxos-tr16.pdf
- Geo distribution of actor based services https://www.microsoft.com/en-us/research/wp-content/uploads/2017/01/Geo-Orleans-TR-012717.pdf
- ??? https://people.eecs.berkeley.edu/~sylvia/cs268-2016/papers//approxsynch.pdf
- Strong consistency models https://aphyr.com/posts/313-strong-consistency-models
- Paxos on steroids https://tschottdorf.github.io/single-decree-paxos-tla-compare-and-swap#discussion-of-cas-paxos
- https://github.com/gryadka/js
- CASPaxos replicated state machines without logs https://arxiv.org/pdf/1802.07000.pdf

##### Updates

- Raft that saves events and not commands should have the same guarantees
- I think it should be possible to make a paxos where the paxos-id chosen is generated from the hash of the content.
- Is there a contention scenario where two nodes can fail to make progress while trying to send the same value?
- If sending content to acceptor then acceptor can try to become proposor with remaining acceptors
- Can you assume the proposor would accept, possibly not it you don't trust proposors i.e. clients.

##### Alt protocol

- save events rather than commands,
  - allows indeterminism in output because one event will fix.
  - allows commands to be rejected
- have ring of nodes where each tries to pass message to next 2/3 for reduced network chatter
- try to localise execution, allows memoisation of results (i.e. state as derived from events)
- a node will pass the message to the last node that committed when it receives a new call,
  up to n times before it executes itself and just divests the result.
  - this will potentially conflict with other events but the consensus manages that.
  If it cannot pass message to master it will do the same
  - the consideration of choosing a valid n is how expensive the computation might be and how frequently the messages come from other places.
  - i.e. if geo separated nodes working for a user then might be reasonable to expect that mojority of requests come to the same node.

If a node looses it's memory it must ask all others for it's state before it can re-gain it's identity.

## Notes

### Consistency / Availability / Partition Tolerance

Pachyderm chooses consistency at all costs within an entity.
Within an entity all activations are guaranteed to be run with latest state.

The combination of `{module, term}` is an entities id.
Only a single entity can be running at any time.

**NOTE: The scope of this guarantee of uniqueness depends on the backend being used.
The default backend for development purposes guarantees this for one node ONLY.**

Make configuring or starting a backend a requirement

### Immortal entities

If an activation fails during exectution, the entity can still be reactivated with the previous persisted state. Followers of an entity will continue to receive updates.

An entity should not make use of `self()` as it will change between activations.

### Actor model

Because sending a message to an entity will automatically create it;
Pachyderm reduces the possible actions of an actor to only two kinds.

1. Sending a message.
2. Updating your own state.

### Prior Art

- whatthehook
  - custom code is pushed by client and is JavaScript so this project has lots of things aroung vm/execution
- Orleans/Erleans

# Outside world

Observation only by looking at state of entities.
Easy to push in new messages. Just interupt with approprite new message
or take existing world and start executing.
Outside can watch and act. e.g. Have a payments to make actor.
This is pulled off by an outside worker that adds messages when done.
If we have at least once delivery we can just retry until done
Test env might want to emulate retries

### File storage for local backend
 Needs to reimplement a log writer for single node for reliable delivery

### Partition on Username registration

Because id can be generated no that the id responsible for Bob is "bo".
`Pachyderm.activate({UsernameRegistration, "bo"}, {:register, "bob", {User, "32123132112"}})`
Have a streaming listener on every node that acts as a cache.

writes are not blocked because partitioning. reads do not hit the writers because of streaming.
The immortal actor world view is then very nice.
Talk at Elixir London meets
This is probably the best motivation for an ability to send diffs. i.e. events.

### CALM

TCP derivation in a client, proxy server system that sends "hello," " World" "!"
Show with reliable broadcast. Then show ordering issues, then message loss then duplication.

### Separated idea of passive active entities

The idea of an active entity is it will be automatically restarted on another machine.
And not just in response to a to an external message.

### Other notes

- Sharded or ets backed supervisor for performance
- Rename Counter.send calls Counter.handle
- use `make_ref()` at compile time to ensure nodes are running the same types.

- names for activate
  - Or activate trigger handle
  - react proceed
  - Or message
- can remove task and do everything inside a process

## Below some old comments on Event sourcing I am keeping around

# Event Sourcing in Elixir

https://www.youtube.com/watch?v=fQPsTEgd48I
https://www.youtube.com/watch?v=R2Aa4PivG0g

https://tech.zilverline.com/2012/07/23/simple-event-sourcing-consistency-part-2

Experiments with eventsourced implementations in elixir.

### Opinions

- Commands don't always produce the same events for a given state, Side effects can occur.
- State must always be the same for a given application of state and event.
- Events are undeniable event application cannot fail so event handle cant have side effects.
- Entities should never exist in invalid states so sould be sent events grouped by transaction.
- An uninitialised state should always accept a creation event therefore we can skip a creation command and directly add creation event to the store

### Counter using Protocols
An event sourced counter with the follow features.
- In memory ledger of events
- State rebuilding of counter from ledger history
- Multi event handling. (1 command can produce multiple events.)
- Supercharged counting state dispatched using elixir protocols

### Lottery Corp
First example, builds entities on top of GenServer

- [Motivational talk for modelling time properly](https://www.youtube.com/watch?v=Nhz5jMXS8gE)
- [Acid 2.0](https://lostechies.com/jimmybogard/2013/06/06/acid-2-0-in-action/)
- [Bloom project](http://boom.cs.berkeley.edu/)
-

https://www.youtube.com/watch?v=66bU45vVF00 talk on bloom


task based UI is a good argument for CQRS and/or event systems

https://cqrs.wordpress.com/documents/task-based-ui/
virtual-strategy.com/2014/11/20/utilizing-task-driven-ui-create-high-performing-and-scalable-business-software/
http://www.uxmatters.com/mt/archives/2014/12/task-driven-user-interfaces.php
