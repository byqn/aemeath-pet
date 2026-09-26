' 爱弥斯 v2 桌面宠 —— 双击本文件即可启动（无控制台窗口）
Option Explicit
Dim shell, fso, here, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\AemeathPet.ps1"
If Not fso.FileExists(script) Then
    MsgBox "找不到 AemeathPet.ps1，请确认本文件与它在同一目录。", 16, "爱弥斯桌宠"
    WScript.Quit 1
End If
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
' 0 = 隐藏窗口，False = 不等待
shell.Run cmd, 0, False
