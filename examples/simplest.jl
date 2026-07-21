using YAMLEvents

# parse_events accepts YAML text and returns a lazy, forward-only event iterator.
source = "greeting: Hello, YAML!\n"

# Iterating does not construct a Dict. Each value describes one syntactic part
# of the stream, document, mapping, or scalar.
for event in parse_events(source)
    println(event)
end
