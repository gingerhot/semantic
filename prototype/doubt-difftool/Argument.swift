/// A list of arguments for the difftool.
enum Argument {
	indirect case OutputFlag(Output, Argument)
	case Sources(Source, Source)

	private var rest: Argument? {
		switch self {
		case let .OutputFlag(_, rest):
			return rest
		case .Sources:
			return nil
		}
	}

	var sources: (Source, Source) {
		switch self {
		case let .Sources(a, b):
			return (a, b)
		case let .OutputFlag(_, rest):
			return rest.sources
		}
	}

	var output: Output {
		func output(argument: Argument, defaultingTo: Output = .Split) -> Output {
			switch argument {
			case let .OutputFlag(f, rest):
				return output(rest, defaultingTo: f)
			default:
				return rest.map { output($0, defaultingTo: defaultingTo) } ?? defaultingTo
			}
		}
		return output(self)
	}

	enum Output {
		case Unified
		case Split
	}
}

private let flag: Madness.Parser<[String], Argument.Output>.Function =
		const(Argument.Output.Unified) <^> satisfy { $0 == "--unified" }
	<|> const(Argument.Output.Split) <^> satisfy { $0 == "--split" }
	<|> pure(Argument.Output.Split)

private let source: Madness.Parser<[String], Source>.Function =
	{ try! Source($0) } <^> satisfy { !$0.hasPrefix("--") }

let argumentsParser: Madness.Parser<[String], Argument>.Function = any // skip the path to the difftool
	*> (curry(Argument.OutputFlag) <^> flag)
	<*> (curry(Argument.Sources) <^> source <*> source)

import Madness
import Prelude
