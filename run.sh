#!/bin/bash
rm src/pometo_lexer.erl
rm src/pometo_parser.erl
rebar3 compile && erl -pa _build/default/lib/pometo/ebin/ -s runner run