module FlycheckJulia

using JSON
using Lint

devnull = nothing

function tryInclude(f::AbstractString)
  old_stdout, old_stderr = Base.STDOUT, Base.STDERR
  redirect_stdout(devnull)
  redirect_stderr(devnull)
  ans = try
    include(f)
    nothing
  catch e
    isa(e, LoadError) || rethrow()
    e
  end
  redirect_stdout(old_stdout)
  redirect_stderr(old_stderr)
  ans
end

# Matches flycheck-define-error-level in flycheck.el
const Severity = Dict('E' => "error", 'W' => "warning", 'I' => "info")

# See Lint/src/messages.jl, this replicates Base.show for LintMessage
# a little, so that we can encode to JSON directly. Base.show is
# designed for printing to stdout
#
# FIXME Can m.message have newlines? What then?
function lintMessage(m::LintMessage)
  Dict("file" => m.file,
       "severity" => Severity[string(m.code)[1]],
       "code" => m.code,
       "line" => m.line,
       "message" =>
       m.scope == "" ? @sprintf("%s: %s", m.variable, m.message) : @sprintf("%s: %s: %s", m.scope, m.variable, m.message)
       )
end

function main(fname::AbstractString, tmpfname::AbstractString)
  # println(STDERR, "FlycheckJulia.jl:main: ", fname, " ", tmpfname)
  # FIXME Does this properly handle files that aren't correctly
  # FIXME enclosed in modules? Probably not?
  le = tryInclude(fname)
  # Anything other than LoadError should fail
  if isa(le, LoadError)
    return JSON.json([Dict("file" => le.file, "line" => le.line, "message" => string(le.error))])
  else
    result = lintfile(fname, readstring(tmpfname))
    return JSON.json([lintMessage(m) for m in result.messages])
  end
  return "null" # (json-encode nil)
end

function main()
  global devnull
  devnull = open(length(ARGS) >= 1 ? ARGS[1] : "/dev/null", "w")
  while true
    request = JSON.parse(readline())
    response = main(request["file"], request["tempfile"])
    println(response)
  end
end

end
