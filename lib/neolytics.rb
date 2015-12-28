require 'neolytics/version'
require 'neolytics/recorder'

module Neolytics
  class << self
    def record_execution(neo4j_session)
      recorder = Recorder.new(neo4j_session)

      recorder.record do
        yield
      end
    end
  end
end