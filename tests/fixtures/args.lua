-- Szenario-Fixture: Argumente wie beim Interpreter (Starter-Modus)
io.stdout:write("args: ", tostring(arg[0]):match("[^/\\]+$"), " ", select("#", ...), " ", table.concat({ ... }, ","),
  " ", tostring(arg[1]), " ", tostring(arg[2]), "\n")
