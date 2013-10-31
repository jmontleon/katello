module Orchestrate
  module Helpers

    module PulpTask

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods

        def generate_phase(phase_module)
          super.tap do |phase_class|
            if phase_module == Dynflow::Action::RunPhase
              phase_class.send(:include, RunMethods)
            end
          end
        end

      end

      module RunMethods

        def wait_for_pulp
          Logging.logger['glue'].debug("pulp task is #{output[:pulp_task]}")
          Logging.logger['glue'].debug("pulp task id is #{output[:pulp_task][:task_id]}")
          if output[:pulp_task].nil? || output[:pulp_task][:task_id].nil?
            raise "output[:pulp_task][:task_id] has to be present to be able to wait for the task"
          end
          suspend
        end

        # needed by dynflow suspend mechanism
        def setup_suspend(suspended_action)
          PulpTask.polling_service.wait_for_task(suspended_action, input[:remote_user], output[:pulp_task][:task_id])
        end

        # invoked by PollingService
        def update_progress(done, pulp_task)
          output.update pulp_task: pulp_task, done: done
        end
      end

      def self.polling_service
        @polling_service ||= PollingService.new(Logging.logger['glue'])
      end


      class PollingService < Dynflow::MicroActor

        Task = Algebrick.type do
          fields(action:    Dynflow::Action::Suspended,
                 pulp_user: String,
                 task_id:   String)
        end

        Tick = Algebrick.type

        def initialize(logger)
          super(logger)
          @tasks    = Set.new
          @progress = Hash.new { |h, k| h[k] = 0 }

          @start_ticker = Queue.new
          @ticker       = Thread.new do
            loop do
              sleep interval
              self << Tick
              @start_ticker.pop
            end
          end
        end

        def wait_for_task(action, pulp_user, task_id)
          # simulate polling for the state of the external task
          self << Task[action,
                       pulp_user,
                       task_id]
        end

        private

        def interval
          0.5
        end

        def on_message(message)
          match(message,
                ~Task >>-> task do
                  @tasks << task
                end,
                Tick >>-> do
                  poll
                end)
        end

        def tick
          @start_ticker << true
        end

        def as_pulp_user(pulp_user)
          ret = nil
          User.set_pulp_config(pulp_user) do
            ret = yield
          end
          return ret
        end

        def poll
          @tasks.delete_if do |task|
            as_pulp_user(task[:pulp_user]) do
              pulp_task = ::Katello.pulp_server.resources.task.poll(task[:task_id])
              done = !! pulp_task[:finish_time]
              task[:action].update_progress(done, pulp_task)
              done
            end
          end
        ensure
          tick
        end
      end

    end
  end
end
