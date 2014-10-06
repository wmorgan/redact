require 'tsort'
require 'socket'
require 'json'
require 'redis'

## A distributed, dependency-aware job scheduler for Redis. Like distributed
## make---you define the dependencies between different parts of your job, and
## Redact handles the scheduling.
class Redact
  include Enumerable

  class TSortHash < Hash
    include TSort
    alias tsort_each_node each_key
    def tsort_each_child node, &block
      deps = self[node] || []
      deps.each(&block)
    end
  end

  ## Options:
  ## * +namespace+: prefix for Redis keys, e.g. "redact/"
  def initialize redis, opts={}
    @namespace = opts[:namespace]
    @redis = redis
    @dag = TSortHash.new

    @queue = [@namespace, "q"].join
    @processing_list = [@namespace, "processing"].join
    @done_list = [@namespace, "done"].join
    @dag_key = [@namespace, "dag"].join
    @metadata_prefix = [@namespace, "metadata"].join
    @params_key = [@namespace, "params"].join
  end

  ## Drop all data and reset the planner.
  def reset!
    keys = [@queue, @processing_list, @done_list, @dag_key, @params_key]
    keys += @redis.keys("#@metadata_prefix/*")
    keys.each { |k| @redis.del k }
  end

  class CyclicDependencyError < StandardError; end

  ## Add a task with dependencies. +What+ is the name of a task (either a symbol
  ## or a string). +Deps+ are any tasks that are dependencies of +what+. +Deps+
  ## may refer to tasks not already added by #add_task; these will be
  ## automatically added without dependencies.
  ##
  ## Raises a CyclicDependencyError exception if adding these dependencies
  ## would result in a cyclic dependency.
  def add_task what, *deps deps = deps.flatten # be nice and allow arrays to be
    passed in raise ArgumentError, "expecting dependencies to be zero or more
    task ids" unless deps.all? { |x| x.is_a?(Symbol) } @dag[what] = deps

    @dag.strongly_connected_components.each do |x|
      raise CyclicDependencyError, "cyclic dependency #{x.inspect}" if x.size != 1
    end
  end

  ## Publish the dependency graph. Must be called at least once before #do!.
  def publish_graph!
    @redis.set @dag_key, @dag.to_json
  end

  ## Schedules +target+ for completion among worker processes listening with
  ## #each. Returns immediately.
  ##
  ## Targets scheduled with #do! have their tasks dispatched in generally FIFO
  ## order; i.e., work for earlier targets will generally be scheduled before
  ## work for later targets. Of course, the actual completion order of targets
  ## depends on the completion orders of dependent tasks, the time required for
  ## these tasks, etc.
  ##
  ## You must call #publish_graph! at least once before calling this.
  ##
  ## +run_id+ is the unique identifier for this run. Don't reuse these.
  ##
  ## +run_params+ are parameters that will be passed to all tasks in this run.
  ## This value will go through JSON round-trips, so should only contain
  ## variable types that are expressible with JSON.
  def do! target, run_id, run_params=nil
    raise ArgumentError, "you haven't called publish_graph!" unless @redis.exists(@dag_key)

    dag = load_dag
    target = target.to_s
    raise ArgumentError, "#{target.inspect} is not a recognized task" unless dag.member?(target)

    @redis.hset @params_key, run_id, run_params.to_json if run_params

    dag.each_strongly_connected_component_from(target) do |tasks|
      task = tasks.first # all single-element arrays by this point
      next unless dag[task].nil? || dag[task].empty? # only push tasks without dependencies
      enqueue_task! task, target, run_id, true
    end
  end

  ## Return the total number of outstanding tasks in the queue. Note that this
  ## is only the number of tasks whose dependencies are satisfied (i.e. those
  ## only those that are currently ready to be performed). Queue size may
  ## fluctuate in both directions as targets are built.
  def size; @redis.llen @queue end

  ## Returns the total number of outstanding tasks currently being processed.
  def processing_list_size; @redis.llen @processing_list end

  ## Returns the total number of completed tasks we have information about.
  def done_list_size; @redis.llen @done_list end

  ## Returns information representing the set of tasks currently in the queue.
  ## The return value is a hash that includes, among other things, these keys:
  ## +task+: the name of the task
  ## +run_id+: the run_id of the task
  ## +target+: the target of the task
  ## +ts+: the timestamp of queue insertion
  def enqueued_tasks start_idx=0, end_idx=-1
    @redis.lrange(@queue, start_idx, end_idx).map { |t| task_summary_for t }
  end

  ## Returns information representing the set of tasks currently in process by
  ## worker processes. The return value is a hash that includes keys from
  ## #enqueued_tasks, plus these keys:
  ## +worker_id+: the worker_id of the worker processing this task
  ## +time_waiting+: the approximate number of seconds this task was enqueued for
  ## +ts+: the timestamp at the start of processing
  def in_progress_tasks start_idx=0, end_idx=-1
    @redis.lrange(@processing_list, start_idx, end_idx).map { |t| task_summary_for t }
  end

  ## Returns information representing the set of tasks that have been
  ## completed. The return value is a hash that includes keys from
  ## #in_progress_tasks, plus these keys:
  ## +worker_id+: the worker_id of the worker processing this task
  ## +time_waiting+: the approximate number of seconds this task was enqueued for
  ## +ts+: the timestamp at the end of processing
  ## +state+: one of "done", "skipped", or "error"
  ## +error+, +backtrace+: debugging information for tasks in state "error"
  ## +time_processing+: the approximate number of seconds this task was processed for
  def done_tasks start_idx=0, end_idx=-1
    @redis.lrange(@done_list, start_idx, end_idx).map { |t| task_summary_for t }
  end

  ## Yields tasks from the queue that are ready for execution. Callers should
  ## then perform the work for those tasks. Any exceptions thrown will result in the
  ## task being reinserted in the queue and tried at a later point (possibly by another
  ## process), unless the retry maximum for that task has been exceeded.
  ##
  ## This method downloads the task graph as necessary, so live updates of the
  ## graph are possible without restarting worker processes.
  ##
  ## +opts+ are:
  ## * +blocking+: if true, #each will block until items are available (and will never return)
  ## * +retries+: how many times an individual job should be retried before resulting in an error state. Default is 2 (so 3 tries total).
  ## * +worker_id+: the id of this worker process, for debugging. (If nil, will use a reasonably intelligent default.)
  def each opts={}
    worker_id = opts[:worker_id] || [Socket.gethostname, $$, $0].join("-")
    retries = opts[:retries] || 2
    blocking = opts[:blocking]

    while true
      ## get the token of the next task to perform
      meth = blocking ? :brpoplpush : :rpoplpush
      token = @redis.send meth, @queue, @processing_list
      break unless token # no more tokens and we're in non-blocking mode

      ## decompose the token
      task, target, run_id, insertion_time = parse_token token

      ## record that we've seen this
      set_metadata! task, run_id, worker_id: worker_id, time_waiting: (Time.now - insertion_time).to_i

      ## load the target state. abort if we don't need to do anything
      target_state = get_state target, run_id
      if (target_state == :error) || (target_state == :done)
        #log "skipping #{task}##{run_id} because #{target}##{run_id} is in state #{target_state}"
        set_metadata! task, run_id, state: :skipped
        commit! token
        next
      end

      ## get any run params
      params = @redis.hget @params_key, run_id
      params = JSON.parse(params) if params
      
      ## ok, let's finally try to perform the task
      begin
        #log "performing #{task}##{run_id}"

        ## the task is now in progress
        set_metadata! task, run_id, state: :in_progress

        ## do it
        startt = Time.now
        yield task.to_sym, run_id, params
        elapsed = Time.now - startt

        ## update total running time
        total_time_processing = elapsed + (get_metadata(task, run_id)[:time_processing] || 0).to_f
        set_metadata! task, run_id, time_processing: total_time_processing

        set_metadata! task, run_id, state: :done
        enqueue_next_tasks! task, target, run_id
        commit! token
      rescue Exception => e
        num_tries = inc_num_tries! task, run_id
        if num_tries > retries # we fail
          set_metadata! target, run_id, state: :error
          set_metadata! task, run_id, state: :error, error: "(#{e.class}) #{e.message}", backtrace: e.backtrace
          commit! token
        else # we'll retry
          uncommit! token
        end

        raise
      end
    end
  end

private

  def load_dag
    dag = JSON.parse @redis.get(@dag_key)
    dag.inject(TSortHash.new) { |h, (k, v)| h[k] = v; h } # i guess
  end

  ## tasks are popped from the right, so at_the_end means lpush, otherwise
  ## rpush.
  def enqueue_task! task, target, run_id, at_the_end=false
    set_metadata! task, run_id, state: :in_queue
    token = make_token task, target, run_id
    at_the_end ? @redis.lpush(@queue, token) : @redis.rpush(@queue, token)
  end

  ## move from processing list to done list
  def commit! token
    @redis.multi do
      @redis.lrem @processing_list, 1, token
      @redis.lpush @done_list, token
    end
  end

  ## move from processing list back to queue
  def uncommit! token
    @redis.multi do # rewind the rpoplpush
      @redis.rpush @queue, token
      @redis.lrem @processing_list, 1, token
    end
  end

  ## make pretty thing for debuggin
  def task_summary_for token
    task, target, run_id, ts = parse_token token
    params = @redis.hget @params_key, run_id
    params = JSON.parse(params) if params
    get_metadata(task, run_id).merge task: task, run_id: run_id, target: target, insertion_time: ts, params: params
  end

  ## enqueue all tasks for +target+ that are unblocked by virtue of having
  ## completed +task+
  def enqueue_next_tasks! task, target, run_id
    ## gimme dag
    dag = load_dag

    ## find all tasks that we block
    blocked = dag.inject([]) { |a, (k, v)| a << k if v.member?(task.to_s); a }

    ## find all tasks in the path to target
    in_path_to_target = [] # sigh... ancient interfaces
    dag.each_strongly_connected_component_from(target) { |x| in_path_to_target << x.first }

    (blocked & in_path_to_target).each do |btask|
      deps = dag[btask]
      dep_states = deps.map { |t| get_state t, run_id }
      if dep_states.all? { |s| s == :done } # we've unblocked it!
        #log "unblocked task #{btask}##{run_id}"
        enqueue_task! btask, target, run_id
      end
    end
  end

  def make_token task, target, run_id;
    [task, target, run_id, Time.now.to_i].to_json
  end

  def parse_token token
    task, target, run_id, ts = JSON.parse token
    [task, target, run_id, Time.at(ts)]
  end

  def metadata_key_for task, run_id; [@metadata_prefix, task, run_id].join(":") end

  def get_state task, run_id
    key = metadata_key_for task, run_id
    (@redis.hget(key, "state") || "unstarted").to_sym
  end

  def inc_num_tries! task, run_id
    key = metadata_key_for task, run_id
    @redis.hincrby key, "tries", 1
  end

  def set_metadata! task, run_id, metadata
    metadata.each { |k, v| metadata[k] = v.to_json unless v.is_a?(String) || v.is_a?(Symbol) }
    metadata[:ts] = Time.now.to_i
    key = metadata_key_for task, run_id
    @redis.mapped_hmset key, metadata
  end

  def get_metadata task, run_id
    key = metadata_key_for task, run_id
    md = @redis.hgetall(key).inject({}) { |h, (k, v)| h[k.to_sym] = v; h }
    md[:ts] = Time.at md[:ts].to_i
    md[:tries] = md[:tries].to_i
    md
  end
end
