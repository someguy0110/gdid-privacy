Option Explicit
Dim shell, command, result

If WScript.Arguments.Count <> 2 Then WScript.Quit 2

Set shell = CreateObject("WScript.Shell")

command = Chr(34) & WScript.Arguments(0) & Chr(34) & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    Chr(34) & WScript.Arguments(1) & Chr(34) & " rotate"

result = shell.Run(command, 0, True)
WScript.Quit result