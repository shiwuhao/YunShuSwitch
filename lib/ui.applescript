-- 云枢界面自动化（供 ysctl 调用）
-- 用法：osascript ui.applescript connect|disconnect|dump|check
-- 返回：OK / NOUI / NOAX / NOBTN / ERR:xxx
--
-- 思路：优先在已有窗口里找按钮；找不到就点开菜单栏状态图标弹出面板再找；
--       仍找不到则唤出主窗口再找。按钮靠「标题 / 描述 / 值 / 子元素文字」关键词匹配。

on run argv
	set act to "connect"
	if (count of argv) > 0 then set act to (item 1 of argv) as text
	if act is "dump" then return my dumpTree()

	try
		tell application "System Events"
			if not (exists process "Yunshu") then return "NOUI"
		end tell
		tell application "System Events" to tell process "Yunshu"
			set frontmost to true
		end tell
	on error errMsg number errNum
		if errNum is -1719 or errNum is -25211 or errNum is -10004 then return "NOAX"
		return "ERR:" & errNum
	end try

	if act is "check" then return "OK"

	if act is "disconnect" then
		set kws to {"断开连接内网", "断开连接", "断开网络"}
		set bads to {"取消"}
	else
		set kws to {"立即连接企业内网", "立即连接", "连接内网", "一键连接"}
		set bads to {"断开", "取消", "申请", "权限", "注销", "自动"}
	end if

	set r to my scan(kws, bads)
	if r is "OK" then return "OK"

	try
		tell application "System Events" to tell process "Yunshu"
			click menu bar item 1 of menu bar 2
		end tell
		delay 1.0
	end try
	set r to my scan(kws, bads)
	if r is "OK" then return "OK"

	try
		do shell script "open -a /Applications/Yunshu.app"
		delay 1.5
	end try
	set r to my scan(kws, bads)
	if r is "OK" then return "OK"

	return "NOBTN"
end run


on scan(kws, bads)
	tell application "System Events" to tell process "Yunshu"
		try
			set wlist to windows
		on error
			return "NO"
		end try
		repeat with w in wlist
			try
				set elems to entire contents of w
			on error
				set elems to {}
			end try
			repeat with e in elems
				try
					if (class of e) is button then
						set lbl to my labelOf(e)
						if my hit(lbl, kws, bads) then
							click e
							return "OK"
						end if
					end if
				end try
			end repeat
		end repeat
	end tell
	return "NO"
end scan


on labelOf(el)
	tell application "System Events"
		set t to ""
		try
			set t to t & " " & (title of el as text)
		end try
		try
			set t to t & " " & (description of el as text)
		end try
		try
			set t to t & " " & (help of el as text)
		end try
		try
			set t to t & " " & (value of el as text)
		end try
		try
			repeat with ch in (UI elements of el)
				try
					set t to t & " " & (title of ch as text)
				end try
				try
					set t to t & " " & (value of ch as text)
				end try
			end repeat
		end try
	end tell
	return t
end labelOf


on hit(lbl, kws, bads)
	repeat with b in bads
		if lbl contains (b as text) then return false
	end repeat
	repeat with k in kws
		if lbl contains (k as text) then return true
	end repeat
	return false
end hit


on dumpTree()
	set out to ""
	try
		tell application "System Events"
			if not (exists process "Yunshu") then return "NOUI"
		end tell
	on error errMsg number errNum
		return "NOAX:" & errNum
	end try

	tell application "System Events" to tell process "Yunshu"
		set out to out & "windows: " & (count of windows) & linefeed
		repeat with w in windows
			try
				set out to out & "  window [" & (class of w as text) & "] " & (name of w as text) & linefeed
			on error
				set out to out & "  window (unnamed)" & linefeed
			end try
			try
				repeat with e in (entire contents of w)
					try
						set c to (class of e) as text
						if c is "button" or c is "check box" or c is "static text" then
							set out to out & "    [" & c & "] " & my labelOf(e) & linefeed
						end if
					end try
				end repeat
			end try
		end repeat
		try
			repeat with mbi in menu bar items of menu bar 2
				set out to out & "  statusItem: " & (description of mbi as text) & linefeed
			end repeat
		end try
	end tell
	return out
end dumpTree
