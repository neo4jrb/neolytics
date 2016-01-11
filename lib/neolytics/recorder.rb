require 'pathname'
require 'parser/current'
require 'neo4apis'
require 'neo4apis/neolytics'

module Neolytics
  class Recorder
    def initialize(neo4j_session)
      @neo4j_session = neo4j_session
      @neo4apis_session = Neo4Apis::Neolytics.new(neo4j_session)
      create_indexes
    end

    def create_indexes
      @neo4j_session.query('CREATE INDEX ON :ASTNode(file_path)')
      @neo4j_session.query('CREATE INDEX ON :ASTNode(first_line)')
      @neo4j_session.query('CREATE INDEX ON :ASTNode(type)')
      @neo4j_session.query('CREATE INDEX ON :ASTNode(name)')

      @neo4j_session.query('CREATE INDEX ON :TracePoint(path)')
      @neo4j_session.query('CREATE INDEX ON :TracePoint(event)')
      @neo4j_session.query('CREATE INDEX ON :TracePoint(lineno)')
      @neo4j_session.query('CREATE INDEX ON :TracePoint(defined_class)')
      @neo4j_session.query('CREATE INDEX ON :TracePoint(method_id)')
      @neo4j_session.query('CREATE INDEX ON :TracePoint(execution_index)')
    end

    def record(&block)
      @neo4apis_session.batch do
        record_execution_trace do
          begin
            block.call
          rescue Exception => e
            nil
          end
        end

        @neo4apis_session.instance_variable_get('@buffer').flush
        query = <<QUERY
MATCH (tp:TracePoint)
WHERE NOT(tp.path IS NULL) AND NOT(tp.path = '(eval)')
RETURN DISTINCT tp.path AS path
QUERY
        file_paths = @neo4j_session.query(query).map(&:path)
        file_paths.each(&method(:record_ast))

        link_query = <<QUERY
MATCH (tp:TracePoint)
WITH tp, tp.lineno AS lineno, tp.path AS path, tp.method_id AS method_id
MATCH (node:ASTNode {type: 'def'})
USING INDEX node:ASTNode(name)
WHERE
  node.name = method_id AND
  node.file_path = path AND
  node.first_line = lineno
MERGE (tp)-[:HAS_AST_NODE]->(node)
QUERY
        @neo4j_session.query(link_query)
      end
    end


    def record_ast(file_path)
      full_path = Pathname.new(file_path).realpath.to_s

      code = File.read(full_path)

      require 'parser/current'
      begin
        root = Parser::CurrentRuby.parse(code)
      rescue EncodingError
        return
      end

      file_node = @neo4apis_session.import :File, full_path, code
      node_node = @neo4apis_session.import :ASTNode, root, file_node
    end


    def record_execution_trace
      execution_index = 0
      indent = 0
      output = ''
      last_tracepoint_node = nil
      last_start_time = nil
      ancestor_stack = []
      run_time_stack = []
      total_run_time_stack = []

      last_tracepoint_end_time = nil
      last_run_time = nil

      trace = TracePoint.new do |tp|
        begin
          last_run_time = 1_000_000.0 * (Time.now - last_tracepoint_end_time) if last_tracepoint_end_time

          start = Time.now
          output << tracepoint_string(tp, indent)

          last_method_time = nil
          if [:call, :c_call].include?(tp.event)
            run_time_stack.push(0)
            total_run_time_stack.push(0)
          elsif [:return, :c_return].include?(tp.event)
            last_method_time = run_time_stack.pop
            last_method_total_time = total_run_time_stack.pop
          else
            #puts "total_run_time_stack: #{total_run_time_stack.inspect}"
            #puts "increment by #{last_run_time}"
            if run_time_stack[-1] && last_run_time
              run_time_stack[-1] += last_run_time
              total_run_time_stack.map! { |i| i + last_run_time }
            end
          end

          associated_call = nil
          if [:return, :c_return].include?(tp.event) && indent.nonzero?
            indent -= 1
            associated_call = ancestor_stack.pop
          elsif [:call, :c_call].include?(tp.event)
            indent += 1
          end

          last_tracepoint_node = @neo4apis_session.import :TracePoint, tp,
                              last_method_time,
                              last_method_total_time,
                              (execution_index += 1),
                              last_tracepoint_node,
                              ancestor_stack.last,
                              associated_call
          
          if [:call, :c_call].include?(tp.event)
            ancestor_stack.push(last_tracepoint_node)
          end

          stop = Time.now
          diff = stop - start
          if diff > 0.5
            puts "time: #{diff}"
            puts "tp: #{tp.inspect}"
          end
          last_tracepoint_end_time = Time.now
        rescue Exception => e
          puts 'EXCEPTION!!'
          puts e.message
          puts e.backtrace
          exit!
        end
      end

      trace.enable
      yield
    ensure
      trace.disable
      puts output
    end

    private

    CYAN = "\e[36m"
    CLEAR = "\e[0m"
    GREEN = "\e[32m"

    def tracepoint_string(tp, indent)
      parts = []
      parts << "#{'|  ' * indent}"
      parts << "#{CYAN if tp.event == :call}%-8s#{CLEAR}"
      parts << "%s:%-4d %-18s\n"
      parts.join(' ') % [tp.event, tp.path, tp.lineno, tp.defined_class.to_s + '#' + GREEN + tp.method_id.to_s + CLEAR]
    end
  end
end