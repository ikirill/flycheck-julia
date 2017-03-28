module FlycheckJulia

using JSON
using Lint

# Matches flycheck-define-error-level in flycheck.el
const Severity = Dict('E' => "error", 'W' => "warning", 'I' => "info")

# See Lint/src/messages.jl, this replicates Base.show for LintMessage
# a little, so that we can encode to JSON directly. Base.show is
# designed for printing to stdout
#
# FIXME Can m.message have newlines? What then?
function lintMessage(m::LintMessage)
  Dict("file" => m.file,
       "severity" => get(Severity, string(m.code)[1], "error"),
       "code" => m.code,
       "line" => m.line,
       "message" =>
       m.scope == "" ? @sprintf("%s: %s", m.variable, m.message) : @sprintf("%s: %s: %s", m.scope, m.variable, m.message)
       )
end

function main(fname::AbstractString, tmpfname::AbstractString)
  # FIXME Does this properly handle files that aren't correctly
  # FIXME enclosed in modules? Probably not?
  result = lintfile(fname, readstring(tmpfname))
  return JSON.json([lintMessage(m) for m in result.messages])
end

function main()
  while true
    request = JSON.parse(readline())
    response = main(request["file"], request["tempfile"])
    println(response)
  end
end

end
