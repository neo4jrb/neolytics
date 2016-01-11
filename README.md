# Neolytics

Welcome to your new gem! In this directory, you'll find the files you need to be able to package up your Ruby library into a gem. Put your Ruby code in the file `lib/neolytics`. To experiment with that code, run `bin/console` for an interactive prompt.

TODO: Delete this and the text above, and describe your gem

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'neolytics'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install neolytics

## Usage

All you need to do to use Neolytics is 

    neo4j_session = Neo4j::Session.open(:server_db, 'http://neo4j:pass@localhost:7474')
    # or
    neo4j_session = Neo4j::Session.current

    Neolytics.record_execution(neo4j_session) do
      # Code that you want to analyze here
    end

During the code execution 

## Model:

Neolytics generates the following structures:

### Abstract Syntax Trees

![Abstract Syntax Tree](examples/model/ast.png)

### TracePoint execution tracking

![Abstract Syntax Tree](examples/model/trace_point_flow.png)

### Objects (including recursively browsed class and modules)

![Abstract Syntax Tree](examples/model/object_relationships.png)

### Links between these domains

TracePoints are linked to AST nodes:

![Abstract Syntax Tree](examples/model/trace_point_ast_nodes.png)

TracePoints are linked to objects (arguments, return values, variable values, context objects):

![Abstract Syntax Tree](examples/model/trace_point_objects.png)

## Example queries:

### Queries using the abstract syntax trees:

#### All defined methods:

```cypher
  MATCH (def:ASTNode {type: 'def'})
  WITH def
  ORDER BY def.file_path, def.first_line
  LIMIT 50
  MATCH shortestPath((def)-[:HAS_PARENT*]->(class:ASTNode {type: 'class'}))
  RETURN def.file_path +':'+ def.first_line AS line, class.name AS class, def.name AS method
```

[Example Output](examples/output/ast.csv)

#### Get all assignments

```cypher
  MATCH (a:ASTNode)
  WHERE a.type IN ['lvasgn', 'ivasgn', 'casgn', 'op_asgn']
  RETURN a.type, a.name, a.operator, a.expression
  ORDER BY a.type, a.name
```

[Example Output](examples/output/assignments.csv)

#### Assignment-Branch-Condition (ABC) Metric

```cypher
  MATCH (def:ASTNode {type: 'def'})

  OPTIONAL MATCH (def)<-[:HAS_PARENT*]-(assignment:ASTNode)
  WHERE assignment.type IN ['lvasgn', 'ivasgn', 'casgn', 'op_asgn']
  WITH def, count(assignment) AS a

  OPTIONAL MATCH (def)<-[:HAS_PARENT*]-(branch:ASTNode)
  WHERE branch.type = 'send'
  WITH def, a, count(branch) AS b

  OPTIONAL MATCH (def)<-[:HAS_PARENT*]-(condition:ASTNode)
  WHERE condition.type IN ['if', 'while', 'until', 'for', 'rescue', 'when', 'and', 'or']
  WITH def, a, b, count(condition) AS c

  RETURN def.name, def.file_path, def.first_line, a, b, c, sqrt((a*a) + (b*b) + (c*c)) AS abc
  ORDER BY abc DESC
```

[Example Output](examples/output/abc.csv)

#### Cyclomatic Complexity

```cypher
  MATCH (def:ASTNode {type: 'def'})
  OPTIONAL MATCH (def)<-[:HAS_PARENT*]-(condition:ASTNode)
  WHERE condition.type IN ['begin', 'if', 'while', 'until', 'for', 'rescue', 'when', 'and', 'or']
  RETURN def.name, def.file_path, def.first_line, count(condition)
  ORDER BY count(condition) DESC
  LIMIT 50
```

[Example Output](examples/output/cyclomatic_complexity.csv)


#### All args / vars / statics / etc... in a class

```cypher
  MATCH (:ASTNode {name: 'Numeric', type: 'class'})<-[:HAS_PARENT*]-(n:ASTNode)
  WHERE n.type IN ['def', 'arg', 'optarg', 'restarg', 'lvar', 'const', 'sym']
  RETURN n.type, n.expression, n.name
  ORDER BY n.type, n.expression
```

[Example Output](examples/output/all_args_vars_statics.csv)

### TracePoint queries

#### Time spent by method

```cypher
  MATCH (tp:TracePoint)
  WITH tp.path AS path, tp.lineno AS line, tp.defined_class AS class, tp.method_id AS method_id, sum(tp.execution_time) AS sum, count(tp) AS count
  ORDER BY sum(tp.execution_time) DESC
  RETURN path +':'+ line AS line, class +'#'+ method_id AS method, sum, count, sum / count AS average
  LIMIT 50
```

[Example Output](examples/output/time_spent_by_method.csv)

#### Common ancestor

```cypher
  MATCH
    (tp1:TracePoint {defined_class: 'ActiveSupport::Autoload', method_id: 'autoload_at'}),
    (tp2:TracePoint {defined_class: 'ActiveSupport::Inflector', method_id: 'underscore'})
  WITH tp1, tp2 LIMIT 1
  MATCH
    path1=(tp1)-[:HAS_PARENT*0..]->(common_ancestor),
    path2=(common_ancestor)<-[:HAS_PARENT*0..]-(tp2:TracePoint)
  RETURN tp1, tp2, common_ancestor, length(path1), length(path2)
```

[Example Output](examples/output/common_ancestor.csv)

#### See all arguments and return values for methods

```cypher
  MATCH (start_tp:TracePoint)
  WHERE start_tp.event = 'call'
  OPTIONAL MATCH (start_tp)-[argument_rel:RECEIVED_ARGUMENT]->(arg:Object)-[:IS_A]->(class:Object)
  WITH
    start_tp,
    collect(argument_rel.argument_name +': '+ arg.ruby_inspect +' ('+ class.ruby_inspect +')') AS arguments

  OPTIONAL MATCH (start_tp)<-[:STARTED_AT]-(return_tp:TracePoint)-[:RETURNED]->(o:Object)-[:IS_A]-(class:Object)
  RETURN
    start_tp.path +':'+ start_tp.lineno AS line,
    start_tp.defined_class +'#'+ start_tp.method_id AS method,
    arguments,
    o.ruby_inspect +' ('+ class.ruby_inspect +')' AS return_object
  ORDER BY start_tp.execution_index
  LIMIT 30
```

[Example Output](examples/output/arguments_and_return_values.csv)

#### Show all returns values from a particular superclass (i.e. Asking for `Numeric` gives `Fixnum`, `Rational`, `BigDecimal`, etc... types)

```cypher
  MATCH (tp:TracePoint)-[:RETURNED]->(o:Object)-[:IS_A]-(class:Object)-[:HAS_SUPERCLASS*]->(superclass:Object {ruby_inspect: 'Numeric'})
  WHERE tp.event IN ['return', 'c_return']
  RETURN tp.path +':'+ tp.lineno AS line, tp.defined_class +'#'+ tp.method_id AS method, o.ruby_inspect +' ('+ class.ruby_inspect +')' AS return_value
  ORDER BY tp.execution_index
```

[Example Output](examples/output/numeric_return_values.csv)

### Object space queries:

#### Show class hierarchy for `Numeric` class:

```cypher
  MATCH (class:Object)-[:HAS_SUPERCLASS*]->(superclass:Object {ruby_inspect: 'Numeric'})
  RETURN *
```

**Example Output:**

![Example Output](examples/output/numeric_class_hierarchy.png)

### Combination queries

#### Combining cyclomatic complexity and run-time metrics

```cypher
  MATCH (tp:TracePoint)
  WITH sum(tp.execution_time) AS total_execution_time

  MATCH (node:ASTNode {type: 'def'})
  OPTIONAL MATCH (node)<-[:HAS_PARENT*]-(condition:ASTNode)
  WHERE condition.type IN ['begin', 'if', 'while', 'until', 'for', 'rescue', 'when', 'and', 'or']
  WITH node, count(condition) AS cyclomatic_complexity, total_execution_time

  MATCH (node)<-[:HAS_AST_NODE]-(tp:TracePoint)<-[:STARTED_AT]-(return_tp:TracePoint)

  WITH
    cyclomatic_complexity,
    total_execution_time,
    tp.path + ':' + tp.lineno + ' (' + return_tp.defined_class + '#' + return_tp.method_id + ')' AS method,
    count(tp) AS executions,
    sum(return_tp.execution_time) AS total_method_execution_time

  RETURN
    method,
    cyclomatic_complexity,
    executions,
    total_method_execution_time,
    100.0 * (total_method_execution_time / total_execution_time) AS percentage_of_total_time,
    total_method_execution_time / executions AS average_execution_time

  ORDER BY total_method_execution_time DESC
```

[Example Output](examples/output/cyclomatic_complexity_and_runtime.csv)

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/neolytics. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

