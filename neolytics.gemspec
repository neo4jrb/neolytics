# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'neolytics/version'

Gem::Specification.new do |spec|
  spec.name          = "neolytics"
  spec.version       = Neolytics::VERSION
  spec.authors       = ["Brian Underwood"]
  spec.email         = ["public@brian-underwood.codes"]

  spec.summary       = %q{Dumps Ruby code analysis data to Neo4j}
  spec.description   = %q{Dumps Ruby code analysis data to Neo4j}
  spec.homepage      = "http://github.com/neo4jrb/neolytics"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'neo4apis', '~> 0.9.0'
  spec.add_dependency 'neo4j-rake_tasks', '~> 0.3.0'
  spec.add_dependency 'parser', '~> 2.2.3.0'
  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"
end
