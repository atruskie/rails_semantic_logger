require_relative "test_helper"
require "sidekiq/processor"

class SidekiqTest < Minitest::Test
  # Cannot use inline testing since it bypasses the Sidekiq logging calls.
  describe Sidekiq::Worker do
    let(:job) { SimpleJob }
    let(:args) { [] }

    describe "#logger" do
      it "has its own logger with the same name as the job" do
        assert_kind_of SemanticLogger::Logger, job.logger
        assert_equal job.logger.name, job.name
        refute_same Sidekiq.logger, job.logger
      end
    end

    describe "#perform" do
      let(:config) { Sidekiq::Config.new(error_handlers: []) }
      let(:msg) { Sidekiq.dump_json({ "class" => job.to_s, "args" => args }) }
      let(:uow) { Sidekiq::BasicFetch::UnitOfWork.new("queue:default", msg) }
      if Sidekiq::VERSION.to_i == 6 && Sidekiq::VERSION.to_f < 6.5
        let(:processor) do
          mgr = Minitest::Mock.new
          opts = {:queues => ['default']}
          opts[:fetch] = Sidekiq::BasicFetch.new(opts)
          Sidekiq::Processor.new(mgr, opts)
        end
      elsif Sidekiq::VERSION.to_i == 6
        let(:processor) do
          config = Sidekiq
          config[:fetch] = Sidekiq::BasicFetch.new(config)
          Sidekiq::Processor.new(config) { |*args| }
        end
      elsif Sidekiq::VERSION.to_i < 7
        let(:processor) do
          mgr = Minitest::Mock.new
          mgr.expect(:options, {:queues => ['default']})
          mgr.expect(:options, {:queues => ['default']})
          mgr.expect(:options, {:queues => ['default']})
          Sidekiq::Processor.new(mgr)
        end
      else
        let(:processor) { Sidekiq::Processor.new(config.default_capsule) { |*args| } }
      end

      it "a simple job" do
        # SimpleJob.perform_async
        messages = semantic_logger_events do
          processor.send(:process, uow)
        end

        assert_equal 2, messages.count, -> { messages.collect(&:to_h).ai }

        assert_semantic_logger_event(
          messages[0],
          level:            :info,
          name:             "SimpleJob",
          message_includes: "Start #perform",
          named_tags:       { class: "SimpleJob", jid: nil }
        )

        assert_semantic_logger_event(
          messages[1],
          level:            :info,
          name:             "SimpleJob",
          message_includes: "Completed #perform",
          metric:           "Sidekiq/SimpleJob/perform",
          named_tags:       { class: "SimpleJob", jid: nil }
        )
      end

      describe "with Bad Job" do
        let(:job) { BadJob }

        it "a job that raises an exception" do
          # BadJob.perform_async
          messages = semantic_logger_events do
            assert_raises ArgumentError do
              processor.send(:process, uow)
            end
          end

          assert_equal 3, messages.count, -> { messages.collect(&:to_h).ai }

          assert_semantic_logger_event(
            messages[0],
            level:      :info,
            name:       "BadJob",
            message:    "Start #perform",
            named_tags: { class: "BadJob", jid: nil }
          )

          assert_semantic_logger_event(
            messages[1],
            level:      :error,
            name:       "BadJob",
            message:    "Completed #perform",
            metric:     "Sidekiq/BadJob/perform",
            named_tags: { class: "BadJob", jid: nil }
          # exception: { name: "ArgumentError", message: "This is a bad job" }
          )

          assert_semantic_logger_event(
            messages[2],
            level:            :warn,
            name:             "BadJob",
            message:          "Job raised exception",
            payload_includes: { context: "Job raised exception", job: { "class" => "BadJob", "args" => [] } }
          # exception: { name: "ArgumentError", message: "This is a bad job" }
          )
        end
      end
    end
  end
end
