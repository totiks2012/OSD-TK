#!/usr/bin/env tclsh

# osd — кратковременное текстовое OSD на Tk.
# Архитектура: процесс на плашку + атомарный реестр в XDG_RUNTIME_DIR.
# Постоянного демона нет. Конфиг у каждой плашки свой (--config).

set ::app         osd
set ::script_dir  [file dirname [file normalize [info script]]]
set ::script_file [file normalize [info script]]

set ::duration       3
set ::position       top-center
set ::margin         10
set ::font            {{DejaVu Sans} 14}
set ::bg             #1d2021
set ::fg             #ebdbb2
set ::border         1
set ::padding        12
set ::wraplength     640
set ::max_height     400
set ::min_font_size  8
set ::align          left
set ::win_w          0
set ::win_h          0
set ::shrink         1
set ::gap            8
set ::max_panels     5
set ::min_show       500
set ::allow_multiple 1

set ::conf_keys {duration position margin font bg fg border padding wraplength \
    max_height min_font_size align win_w win_h shrink gap max_panels min_show allow_multiple}
set ::conf_defaults {}
foreach _k $::conf_keys { dict set ::conf_defaults $_k [set ::$_k] }
unset -nocomplain _k

set ::runtime_dir ""
set ::panels_dir  ""
set ::fifos_dir   ""
set ::spool_dir   ""
set ::lock_dir    ""
set ::legacy_pid  ""
set ::legacy_fifo ""

set ::panel_id    ""
set ::panel_path  ""
set ::panel_fifo  ""
set ::panel_ch    ""
set ::panel_buf   ""
set ::panel_born  ""
set ::panel_anchor ""
set ::panel_key   "default"
set ::panel_kind  "event"
set ::panel_prio  0
set ::panel_sticky 0
set ::panel_min_show 500
set ::panel_conf    ""
set ::panel_conf_sig ""
set ::cli_duration  ""
set ::cli_min_show  ""

set ::osd_font  ""
set ::label     ""
set ::timer     ""
set ::visible   0
set ::font_sign 1
set ::font_abs  14
set ::text      ""
set ::clip_mode ""
set ::clip_active 0
set ::clip_retire ""
set ::clip_ttl  20000
set ::cur_y     0
set ::cur_w     0
set ::cur_h     0
set ::closing   0

proc usage {{msg ""}} {
    if {$msg ne ""} { puts stderr "$::app: $msg" }
    puts stderr "usage: [file tail $::argv0] \[--config FILE] \[--file FILE|-] \[--kill|--dump|--help] \[--] \[TEXT...\]"
    puts stderr "       [file tail $::argv0] \[--key K --kind state|event --prio N --sticky 0|1\] \[--duration SEC\]"
    exit 2
}

proc help {} {
    puts {osd — кратковременное текстовое OSD на Tk

Использование:
  osd "текст"
  printf 'строка 1\nстрока 2' | osd
  osd --file FILE
  osd -                      # явно читать stdin
  osd --kill                 # закрыть все плашки
  osd --dump                 # напечатать текст и выйти (без окна)

Опции:
  --config FILE   явный конфиг (key=value) для этой плашки
  -f, --file FILE читать текст из файла; FILE=- означает stdin
  -               читать stdin (даже если это терминал)
  --kill          закрыть все видимые плашки
  --dump          вывести принятый текст в stdout и выйти
  --key K         канал плашки (по умолчанию event/default)
  --kind K        state | event (state обновляет плашку с тем же --key)
  --prio N        приоритет для вытеснения (больше — важнее)
  --sticky 0|1    не вытеснять автоматически
  --duration SEC  переопределить duration из конфига
  --min-show MS   минимальное время показа при вытеснении
  -h, --help      эта справка
  --              конец опций; дальше текст может начинаться с '-'

Управление окном:
  ЛКМ        скопировать текст в PRIMARY и CLIPBOARD
  ПКМ        закрыть эту плашку
  Esc        закрыть эту плашку (если окно в фокусе)

Источники текста (ровно один):
  аргументы | --file | - | stdin-пайп
  Если аргументов нет, stdin — терминал, и '-' не указан:
  выводится сообщение «нет stdin и не передан текст».

Конфиг ищется в порядке:
  1) --config FILE
  2) $OSD_CONF
  3) ./osd.conf
  4) osd.conf рядом с osd.tcl
  5) встроенные значения

Каждая плашка читает свой конфиг один раз. Изменение файла
не влияет на уже видимые плашки — только на новые.

Ключи osd.conf:
  duration=3          секунды показа; 0 — до ПКМ/Esc
  position=top-center top-left|top-center|top-right|middle-left|center|
                      middle-right|bottom-left|bottom-center|bottom-right
  margin=10           отступ от края экрана
  font={DejaVu Sans} 14
  bg=#1d2021
  fg=#ebdbb2
  border=1
  padding=12
  wraplength=640      максимальная ширина текста в px (0 — авто)
  max_height=400      максимальная высота окна в px (0 — авто)
  win_w=0             фиксированная ширина окна в px (0 — по тексту)
  win_h=0             фиксированная высота окна в px (0 — по тексту)
  shrink=1            1 — уменьшать шрифт/обрезать под окно, 0 — нет
  min_font_size=8     предел уменьшения шрифта перед обрезкой
  align=left          left|center|right
  gap=8               отступ между плашками в одной группе
  max_panels=5        максимум одновременно видимых плашек
  min_show=500        мс; защита от вытеснения слишком рано
  allow_multiple=1    1 — разрешать несколько плашек с одним --key;
                      0 — повторный вызов обновляет существующую плашку

Плашки с одинаковым position образуют группу. Новая встаёт ниже
предыдущей (для bottom-* — выше), существующие не двигаются.
}
    exit 0
}

proc die {msg {rc 1}} {
    puts stderr "$::app: $msg"
    exit $rc
}

proc sleep_ms {ms} {
    after $ms
}

proc normalize_position {p} {
    set p [string tolower [string trim $p]]
    switch -- $p {
        top           { return top-center }
        bottom        { return bottom-center }
        left          { return middle-left }
        right         { return middle-right }
        middle        { return center }
        top-left - top-center - top-right -
        middle-left - center - middle-right -
        bottom-left - bottom-center - bottom-right { return $p }
    }
    return ""
}

proc is_tty {channel} {
    if {[catch {exec test -t 0}]} { return 0 }
    return 1
}

proc normalize_text {t} {
    set t [string map {"\r\n" "\n" "\r" "\n" "\x00" ""} $t]
    return [string trimright $t "\n"]
}

proc read_stdin {} {
    fconfigure stdin -translation auto -encoding utf-8
    return [normalize_text [read stdin]]
}

proc collect_text {file use_stdin args} {
    set sources 0
    if {$file ne ""} { incr sources }
    if {$use_stdin} { incr sources }
    if {[llength $args] > 0} { incr sources }
    if {$sources > 1} {
        die "укажи только один источник текста" 2
    }
    if {$file ne ""} {
        if {$file eq "-"} { return [read_stdin] }
        if {![file readable $file]} { die "файл не читается: $file" 1 }
        return [normalize_text [read_file $file]]
    }
    if {$use_stdin} { return [read_stdin] }
    if {[llength $args] > 0} {
        return [normalize_text [join $args " "]]
    }
    if {![is_tty stdin]} { return [read_stdin] }
    die "нет stdin и не передан текст" 2
}

proc read_file {path} {
    set ch [open $path r]
    fconfigure $ch -translation auto -encoding utf-8
    set data [read $ch]
    close $ch
    return $data
}

proc read_binary {path} {
    set ch [open $path r]
    fconfigure $ch -translation binary -encoding binary
    set data [read $ch]
    close $ch
    return $data
}

proc atomic_write {path data} {
    set dir [file dirname $path]
    set tmp [file join $dir ".tmp-[pid]-[clock milliseconds]-[expr {int(rand()*1000000)}]"]
    set ch [open $tmp w]
    fconfigure $ch -translation lf -encoding utf-8
    puts -nonewline $ch $data
    close $ch
    catch {file attributes $tmp -permissions 0600}
    file rename -force $tmp $path
}

proc set_paths {} {
    set dir ""
    if {[info exists ::env(XDG_RUNTIME_DIR)] &&
        $::env(XDG_RUNTIME_DIR) ne "" &&
        [file isdirectory $::env(XDG_RUNTIME_DIR)]} {
        set dir $::env(XDG_RUNTIME_DIR)
    } else {
        set dir /tmp
    }

    set uid 0
    if {![catch {file stat /proc/self st}] && [info exists st(uid)]} {
        set uid $st(uid)
    }
    set tag $uid
    if {$uid == 0} {
        set user [expr {[info exists ::env(USER)] ? $::env(USER) : $::tcl_platform(user)}]
        regsub -all {[^A-Za-z0-9_.-]} $user _ user
        set tag $user
    }
    set legacy_tag "$tag-v2"
    set tag "$tag-v3"

    set ::runtime_dir [file join $dir "osd-$tag"]
    set ::panels_dir  [file join $::runtime_dir panels]
    set ::fifos_dir   [file join $::runtime_dir fifos]
    set ::spool_dir   [file join $::runtime_dir spool]
    set ::lock_dir    [file join $::runtime_dir lock]
    set ::legacy_pid  [file join $dir "osd-$legacy_tag.pid"]
    set ::legacy_fifo [file join $dir "osd-$legacy_tag.fifo"]

    foreach d [list $::runtime_dir $::panels_dir $::fifos_dir $::spool_dir] {
        if {![file exists $d]} {
            file mkdir $d
            catch {file attributes $d -permissions 0700}
        } elseif {![file isdirectory $d]} {
            die "путь $d существует и это не каталог" 1
        }
    }
    catch {file attributes $::runtime_dir -permissions 0700}
}

proc resolve_config {explicit} {
    if {$explicit ne ""} {
        if {![file readable $explicit]} {
            die "конфиг не читается: $explicit" 1
        }
        return [file normalize $explicit]
    }
    if {[info exists ::env(OSD_CONF)] && $::env(OSD_CONF) ne ""} {
        if {![file readable $::env(OSD_CONF)]} {
            die "OSD_CONF не читается: $::env(OSD_CONF)" 1
        }
        return [file normalize $::env(OSD_CONF)]
    }
    set local [file join [pwd] osd.conf]
    if {[file readable $local]} { return [file normalize $local] }
    set near [file join $::script_dir osd.conf]
    if {[file readable $near]} { return [file normalize $near] }
    return ""
}

proc is_color {c} {
    if {[catch {winfo rgb . $c}]} { return 0 }
    return 1
}

proc load_config {path} {
    if {$path eq "" || ![file readable $path]} { return }
    set ch [open $path r]
    fconfigure $ch -encoding utf-8
    set n 0
    while {[gets $ch line] >= 0} {
        incr n
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set eq [string first "=" $line]
        if {$eq < 1} {
            puts stderr "$::app: $path:$n: expected key=value"
            continue
        }
        set k [string trim [string range $line 0 [expr {$eq - 1}]]]
        set v [string trim [string range $line [expr {$eq + 1}] end]]
        switch -- $k {
            duration - margin - border - padding - wraplength - max_height - win_w - win_h - gap {
                if {[string is integer -strict $v] && $v >= 0} {
                    set ::$k $v
                } else {
                    puts stderr "$::app: $path:$n: $k must be a non-negative integer"
                }
            }
            max_panels {
                if {[string is integer -strict $v] && $v > 0} {
                    set ::max_panels $v
                } else {
                    puts stderr "$::app: $path:$n: max_panels must be a positive integer"
                }
            }
            min_show {
                if {[string is integer -strict $v] && $v >= 0} {
                    set ::min_show $v
                } else {
                    puts stderr "$::app: $path:$n: min_show must be a non-negative integer"
                }
            }
            min_font_size {
                if {[string is integer -strict $v] && $v > 0} {
                    set ::min_font_size $v
                } else {
                    puts stderr "$::app: $path:$n: min_font_size must be a positive integer"
                }
            }
            position {
                set np [normalize_position $v]
                if {$np eq ""} {
                    puts stderr "$::app: $path:$n: unknown position '$v'"
                } else {
                    set ::position $np
                }
            }
            font {
                if {$v ne ""} {
                    set ::font $v
                } else {
                    puts stderr "$::app: $path:$n: empty font"
                }
            }
            bg - fg {
                if {[is_color $v]} {
                    set ::$k $v
                } else {
                    puts stderr "$::app: $path:$n: bad color '$v' for $k"
                }
            }
            align {
                set a [string tolower $v]
                if {$a in {left center right}} {
                    set ::align $a
                } else {
                    puts stderr "$::app: $path:$n: align must be left|center|right"
                }
            }
            shrink - allow_multiple {
                set b [string tolower $v]
                if {$b in {1 true yes on}} {
                    set ::$k 1
                } elseif {$b in {0 false no off}} {
                    set ::$k 0
                } else {
                    puts stderr "$::app: $path:$n: $k must be 0|1"
                }
            }
            default {
                puts stderr "$::app: $path:$n: unknown key '$k'"
            }
        }
    }
    close $ch
}

proc reset_config {} {
    dict for {k v} $::conf_defaults { set ::$k $v }
}

proc conf_signature {path} {
    if {$path eq "" || ![file readable $path]} { return "" }
    set mt 0
    catch {set mt [file mtime $path]}
    set sz 0
    catch {set sz [file size $path]}
    return "$path|$mt|$sz"
}

proc pid_is_osd {p} {
    if {![string is integer -strict $p] || $p <= 0} { return 0 }
    if {[catch {exec kill -0 $p}]} { return 0 }
    set f /proc/$p/cmdline
    if {![file readable $f]} { return 0 }
    if {[catch {set cmd [read_binary $f]}]} { return 0 }
    return [expr {[string first "osd.tcl" $cmd] >= 0 || [string first "--panel" $cmd] >= 0}]
}

proc pid_alive {p} {
    if {![string is integer -strict $p] || $p <= 0} { return 0 }
    return [expr {![catch {exec kill -0 $p}]}]
}

proc lock_acquire {} {
    set deadline [expr {[clock milliseconds] + 4000}]
    while {[clock milliseconds] < $deadline} {
        if {![catch {exec mkdir -m 700 $::lock_dir}]} {
            if {![catch {
                set ch [open [file join $::lock_dir owner] w]
                puts $ch [pid]
                close $ch
            }]} {
                return 1
            }
            catch {file delete -force $::lock_dir}
        }
        set owner ""
        if {[file readable [file join $::lock_dir owner]]} {
            catch {set owner [string trim [read_file [file join $::lock_dir owner]]]}
        }
        set age 0
        if {![catch {file mtime $::lock_dir} mt]} {
            set age [expr {[clock seconds] - $mt}]
        }
        set stale 0
        if {$owner eq ""} {
            if {$age > 2} { set stale 1 }
        } elseif {![pid_is_osd $owner]} {
            set stale 1
        } elseif {$age > 30} {
            set stale 1
        }
        if {$stale} {
            set stale_dir [file join $::runtime_dir "lock.stale-[pid]-[clock milliseconds]-[expr {int(rand()*1000000)}]"]
            if {![catch {file rename $::lock_dir $stale_dir}]} {
                catch {file delete -force $stale_dir}
            }
            continue
        }
        after 3
    }
    return 0
}

proc lock_release {} {
    set owner ""
    if {[file readable [file join $::lock_dir owner]]} {
        catch {set owner [string trim [read_file [file join $::lock_dir owner]]]}
    }
    if {$owner eq [pid] || $owner eq ""} {
        catch {file delete -force $::lock_dir}
    }
}

proc entry_serialize {e} {
    set out {}
    dict for {k v} $e { lappend out [list $k $v] }
    return $out
}

proc entry_parse {data} {
    set d [dict create]
    if {[catch {
        foreach pair $data {
            if {[llength $pair] == 2} {
                dict set d [lindex $pair 0] [lindex $pair 1]
            }
        }
    }]} {
        return [dict create]
    }
    return $d
}

proc write_entry {path e} {
    atomic_write $path [entry_serialize $e]
}

proc entry_file {seq id} {
    return [file join $::panels_dir [format "%010d-%s" $seq $id]]
}

proc list_entries_locked {} {
    set out {}
    foreach f [lsort [glob -nocomplain -directory $::panels_dir *]] {
        if {[file tail $f] eq "" || [string index [file tail $f] 0] eq "."} continue
        if {[catch {set d [entry_parse [read_file $f]]}]} continue
        if {[dict size $d] == 0} continue
        dict set d _file $f
        lappend out $d
    }
    return $out
}

proc sweep_dead_locked {} {
    set out {}
    set removed 0
    foreach e [list_entries_locked] {
        set p [dict get $e pid]
        if {[pid_is_osd $p]} {
            lappend out $e
        } else {
            catch {file delete -force [dict get $e _file]}
            catch {file delete -force [dict get $e fifo]}
            incr removed
        }
    }
    return [list $out $removed]
}

proc next_seq {entries} {
    set max 0
    foreach e $entries {
        if {[dict exists $e born_seq]} {
            set s [dict get $e born_seq]
            if {[string is integer -strict $s] && $s > $max} { set max $s }
        }
    }
    return [expr {$max + 1}]
}

proc find_self {entries id} {
    foreach e $entries {
        if {[dict get $e id] eq $id} { return $e }
    }
    return ""
}

proc find_reuse_target {} {
    if {[lock_acquire] == 0} { return "" }
    set entries [lindex [sweep_dead_locked] 0]
    set best ""
    foreach e $entries {
        if {[dict get $e key] ne $::panel_key} continue
        if {$best eq "" || [dict get $e born_seq] > [dict get $best born_seq]} {
            set best $e
        }
    }
    lock_release
    return $best
}

proc drop_panel_entry {id} {
    if {[lock_acquire] == 0} { return }
    set entries [lindex [sweep_dead_locked] 0]
    foreach e $entries {
        if {[dict get $e id] eq $id} {
            catch {file delete -force [dict get $e _file]}
            catch {file delete -force [dict get $e fifo]}
            break
        }
    }
    lock_release
}

proc group_entries {entries anchor} {
    set out {}
    foreach e $entries {
        if {[dict get $e anchor] eq $anchor} { lappend out $e }
    }
    return [lsort -integer -index 0 [lmap e $out {
        list [dict get $e born_seq] $e
    }]]
}

proc group_panels {entries anchor} {
    set out {}
    foreach pair [group_entries $entries $anchor] { lappend out [lindex $pair 1] }
    return $out
}

proc compute_y {entries id sw sh gap} {
    set self [find_self $entries $id]
    if {$self eq ""} { return "" }
    set anchor [dict get $self anchor]
    set group [group_panels $entries $anchor]
    if {[llength $group] == 0} { return "" }
    set ids {}
    foreach e $group { lappend ids [dict get $e id] }
    set k [lsearch -exact $ids $id]
    if {$k < 0} { return "" }
    set first [lindex $group 0]
    set margin [dict get $first margin]
    set bottom [string match "bottom-*" $anchor]
    set middle [string match "middle-*" $anchor]
    if {$bottom} {
        set y [expr {$sh - $margin}]
        for {set i 0} {$i < $k} {incr i} {
            set y [expr {$y - [dict get [lindex $group $i] h] - $gap}]
        }
        set y [expr {$y - [dict get [lindex $group $k] h]}]
        return $y
    }
    if {$middle} {
        set y [expr {($sh - [dict get $first h]) / 2}]
    } else {
        set y $margin
    }
    for {set i 0} {$i < $k} {incr i} {
        set y [expr {$y + [dict get [lindex $group $i] h] + $gap}]
    }
    return $y
}

proc compute_x {w position sw margin} {
    switch -- $position {
        top-left - middle-left - bottom-left { return $margin }
        top-right - middle-right - bottom-right { return [expr {$sw - $w - $margin}] }
        default { return [expr {($sw - $w) / 2}] }
    }
}

proc fifo_send {path msg} {
    if {$path eq "" || ![file exists $path]} { return 0 }
    set ch ""
    if {[catch {open $path {WRONLY NONBLOCK}} ch]} { return 0 }
    set ok 0
    if {![catch {
        fconfigure $ch -translation binary -buffering none
        puts -nonewline $ch "$msg\n"
        flush $ch
        set ok 1
    }]} {}
    catch {close $ch}
    return $ok
}

proc broadcast {msg fifos {skip ""}} {
    foreach f $fifos {
        if {$f eq "" || $f eq $skip} continue
        fifo_send $f $msg
    }
}

proc other_fifos {entries selfid} {
    set out {}
    set anchor ""
    foreach e $entries {
        if {[dict get $e id] eq $selfid} { set anchor [dict get $e anchor] }
    }
    if {$anchor eq ""} { return $out }
    foreach e [group_panels $entries $anchor] {
        if {[dict get $e id] ne $selfid} { lappend out [dict get $e fifo] }
    }
    return $out
}

proc panel_ack {path msg} {
    if {$path eq ""} { return }
    if {[catch {atomic_write $path $msg}]} {}
}

proc clip_tool {} {
    if {[info exists ::env(WAYLAND_DISPLAY)] && $::env(WAYLAND_DISPLAY) ne ""} {
        foreach t {wl-copy xclip xsel} {
            if {[auto_execok $t] ne ""} { return $t }
        }
    }
    if {[info exists ::env(DISPLAY)] && $::env(DISPLAY) ne ""} {
        foreach t {xclip xsel} {
            if {[auto_execok $t] ne ""} { return $t }
        }
    }
    foreach t {wl-copy xclip xsel} {
        if {[auto_execok $t] ne ""} { return $t }
    }
    return ""
}

proc clip_copy {text} {
    set okp 0
    set okc 0
    switch -- $::clip_mode {
        wl-copy {
            set okp [expr {![catch {exec wl-copy --primary << $text >/dev/null 2>&1}]}]
            set okc [expr {![catch {exec wl-copy << $text >/dev/null 2>&1}]}]
        }
        xclip {
            set okp [expr {![catch {exec xclip -selection primary -in << $text >/dev/null 2>&1}]}]
            set okc [expr {![catch {exec xclip -selection clipboard -in << $text >/dev/null 2>&1}]}]
        }
        xsel {
            set okp [expr {![catch {exec xsel --primary --input << $text >/dev/null 2>&1}]}]
            set okc [expr {![catch {exec xsel --clipboard --input << $text >/dev/null 2>&1}]}]
        }
    }
    if {$okp && $okc} { return 1 }
    return [clip_keeper_set $text]
}

proc clip_keeper_set {text} {
    if {![winfo exists .clip]} {
        toplevel .clip
        catch {wm overrideredirect .clip 1}
        wm geometry .clip 1x1+0+0
        catch {wm attributes .clip -alpha 0.0}
        text .clip.t -width 1 -height 1 -takefocus 0 -bd 0 -highlightthickness 0
        pack .clip.t
        lower .clip
    }
    .clip.t delete 1.0 end
    .clip.t insert 1.0 $text
    .clip.t tag add sel 1.0 end
    catch {selection own -selection PRIMARY .clip.t}
    catch {clipboard clear}
    catch {clipboard append $text}
    set ::clip_active 1
    catch {after cancel $::clip_retire}
    set ::clip_retire [after $::clip_ttl {clip_keeper_retire}]
    return 1
}

proc clip_keeper_retire {} {
    set ::clip_retire ""
    set ::clip_active 0
    if {[selection own -selection PRIMARY] ne ""} {
        catch {selection clear -selection PRIMARY}
    }
    if {!$::visible} { panel_exit 0 }
}

proc copy_current {} {
    if {$::text eq ""} { return }
    clip_copy $::text
}

proc build_window {} {
    wm withdraw .
    wm title . $::app
    wm overrideredirect . 1
    catch {wm attributes . -topmost 1}
    catch {wm attributes . -type tooltip}

    if {[catch {font actual $::font} desc]} {
        error "плохой шрифт '$::font': $desc"
    }
    set ::osd_font [font create ::osd_font {*}$desc]
    set ::font_abs [expr {abs([font configure $::osd_font -size])}]
    set ::font_sign [expr {[font configure $::osd_font -size] < 0 ? -1 : 1}]

    set ::label [label .l -anchor nw -justify $::align -font $::osd_font \
        -fg $::fg -bg $::bg -bd 0 -padx $::padding -pady $::padding \
        -highlightthickness $::border -highlightbackground $::fg \
        -highlightcolor $::fg -text ""]
    label .measure -anchor nw -justify $::align -font $::osd_font \
        -bd 0 -padx $::padding -pady $::padding \
        -highlightthickness $::border -text ""
    pack $::label -fill both -expand 1

    bind . <Button-1> {copy_current}
    bind . <Button-3> {panel_close}
    bind . <Escape>   {panel_close}
}

proc text_height {t} {
    .measure configure -text $t
    update idletasks
    return [winfo reqheight .measure]
}

proc truncate_text {text maxh} {
    set lo 0
    set hi [string length $text]
    set best ""
    while {$lo <= $hi} {
        set mid [expr {($lo + $hi) / 2}]
        set cand [string range $text 0 [expr {$mid - 1}]]
        set cand "[string trimright $cand]…"
        if {[text_height $cand] <= $maxh} {
            set best $cand
            set lo [expr {$mid + 1}]
        } else {
            set hi [expr {$mid - 1}]
        }
    }
    if {$best eq ""} { set best "…" }
    return $best
}

proc render_text {} {
    set maxw [expr {[winfo screenwidth .] - 2 * $::margin - 2 * $::padding - 2 * $::border - 4}]
    if {$maxw < 160} { set maxw 160 }
    if {$::win_w > 0} {
        set wrap [expr {$::win_w - 2 * $::padding - 2 * $::border}]
        if {$wrap < 1} { set wrap 1 }
    } else {
        set wrap $::wraplength
        if {$wrap <= 0 || $wrap > $maxw} { set wrap $maxw }
    }

    set maxh $::max_height
    if {$::win_h > 0} {
        set maxh [expr {$::win_h - 2 * $::padding - 2 * $::border}]
        if {$maxh < 1} { set maxh 1 }
    } else {
        set sh [winfo screenheight .]
        if {$maxh <= 0 || $maxh > $sh - 2 * $::margin} {
            set maxh [expr {$sh - 2 * $::margin}]
        }
    }

    if {$::win_w > 0 || $::win_h > 0} {
        $::label  configure -anchor center -justify center
        .measure configure -anchor center -justify center
    } else {
        $::label  configure -anchor nw -justify $::align
        .measure configure -anchor nw -justify $::align
    }

    .measure configure -wraplength $wrap

    if {!$::shrink} {
        font configure $::osd_font -size [expr {$::font_sign * $::font_abs}]
        $::label configure -wraplength $wrap -text $::text
        update idletasks
        return
    }

    set sizes {}
    for {set s $::font_abs} {$s >= $::min_font_size} {incr s -2} {
        lappend sizes $s
    }
    if {[llength $sizes] == 0} { lappend sizes $::font_abs }

    set final $::text
    set fit 0
    foreach s $sizes {
        font configure $::osd_font -size [expr {$::font_sign * $s}]
        if {[text_height $::text] <= $maxh} {
            set fit 1
            break
        }
    }

    if {!$fit} {
        set s [lindex $sizes end]
        font configure $::osd_font -size [expr {$::font_sign * $s}]
        set final [truncate_text $::text $maxh]
    }

    $::label configure -wraplength $wrap -text $final
    update idletasks
}

proc reset_timer {} {
    catch {after cancel $::timer}
    set ::timer ""
    if {$::duration > 0} {
        set ::timer [after [expr {$::duration * 1000}] {panel_close}]
    }
}

proc measure_self {} {
    update idletasks
    set ::cur_w [winfo reqwidth .]
    set ::cur_h [winfo reqheight .]
    if {$::win_w > 0} { set ::cur_w $::win_w }
    if {$::win_h > 0} { set ::cur_h $::win_h }
}

proc place_at {y} {
    set sw [winfo screenwidth .]
    set x [compute_x $::cur_w $::position $sw $::margin]
    wm geometry . "${::cur_w}x${::cur_h}+${x}+${y}"
    set ::cur_y $y
}

proc panel_entry {} {
    return [dict create \
        id $::panel_id \
        pid [pid] \
        key $::panel_key \
        kind $::panel_kind \
        prio $::panel_prio \
        sticky $::panel_sticky \
        min_show $::panel_min_show \
        born_seq $::panel_seq \
        anchor $::position \
        margin $::margin \
        gap $::gap \
        w $::cur_w \
        h $::cur_h \
        y $::cur_y \
        conf $::panel_conf \
        conf_sig $::panel_conf_sig \
        fifo $::panel_fifo]
}

proc register_self {} {
    if {[lock_acquire] == 0} { return -code error "не удалось взять lock реестра" }
    lassign [sweep_dead_locked] entries removed
    set ::panel_seq [next_seq $entries]
    set path [entry_file $::panel_seq $::panel_id]
    set ::panel_path $path
    set self [panel_entry]
    lappend entries $self
    set y [compute_y $entries $::panel_id [winfo screenwidth .] [winfo screenheight .] $::gap]
    if {$y eq ""} { set y $::margin }
    set ::cur_y $y
    write_entry $path [panel_entry]
    set peers [other_fifos $entries $::panel_id]

    set victim ""
    set all [list_entries_locked]
    set sh [winfo screenheight .]
    set off 0
    if {[string match "bottom-*" $::position]} {
        if {$y < $::margin} { set off 1 }
    } else {
        if {[expr {$y + $::cur_h}] > [expr {$sh - $::margin}]} { set off 1 }
    }
    if {[llength $all] > $::max_panels || $off} {
        set cand {}
        foreach e $all {
            if {[dict get $e id] eq $::panel_id} continue
            if {[dict get $e sticky] ne "0"} continue
            if {$off && [dict get $e born_seq] >= $::panel_seq} continue
            lappend cand $e
        }
        set cand [lsort -command {apply {{a b} {
            set pa [dict get $a prio]; set pb [dict get $b prio]
            if {$pa ne $pb} { return [expr {$pa - $pb}] }
            return [expr {[dict get $a born_seq] - [dict get $b born_seq]}]
        }}} $cand]
        if {[llength $cand] > 0} { set victim [dict get [lindex $cand 0] fifo] }
    }
    lock_release
    if {$removed > 0} { broadcast "reflow" $peers }
    if {$victim ne ""} { fifo_send $victim "evict" }
}

proc update_self_entry {} {
    if {[lock_acquire] == 0} { return }
    set entries [lindex [sweep_dead_locked] 0]
    set self [find_self $entries $::panel_id]
    if {$self eq ""} {
        lock_release
        return
    }
    set path [dict get $self _file]
    set old_anchor [dict get $self anchor]
    set old_fifos {}
    foreach e $entries {
        if {[dict get $e id] eq $::panel_id} continue
        if {[dict get $e anchor] eq $old_anchor} { lappend old_fifos [dict get $e fifo] }
    }
    set updated [panel_entry]
    set entries [lmap e $entries {
        if {[dict get $e id] eq $::panel_id} { set updated } else { set e }
    }]
    set y [compute_y $entries $::panel_id [winfo screenwidth .] [winfo screenheight .] $::gap]
    if {$y eq ""} { set y $::cur_y }
    set ::cur_y $y
    set updated [panel_entry]
    write_entry $path $updated
    set new_fifos [other_fifos $entries $::panel_id]
    set fifos [lsort -unique [concat $old_fifos $new_fifos]]
    lock_release
    place_at $y
    broadcast "reflow" $fifos
}

proc refresh_layout {} {
    if {$::closing} { return }
    if {[lock_acquire] == 0} { return }
    lassign [sweep_dead_locked] entries removed
    set self [find_self $entries $::panel_id]
    if {$self eq ""} {
        lock_release
        panel_exit 0
    }
    set peers [other_fifos $entries $::panel_id]
    set y [compute_y $entries $::panel_id [winfo screenwidth .] [winfo screenheight .] $::gap]
    if {$y ne ""} {
        set ::cur_y $y
        write_entry [dict get $self _file] [panel_entry]
    }
    lock_release
    if {$y ne ""} { place_at $y }
    if {$removed > 0} { broadcast "reflow" $peers }
}

proc remove_self_and_broadcast {} {
    if {[lock_acquire] == 0} { return }
    set entries [lindex [sweep_dead_locked] 0]
    set self [find_self $entries $::panel_id]
    set fifos {}
    if {$self ne ""} {
        set anchor [dict get $self anchor]
        catch {file delete -force [dict get $self _file]}
        set remaining [lmap e $entries {
            if {[dict get $e id] eq $::panel_id} { continue } else { set e }
        }]
        foreach e $remaining {
            if {[dict get $e anchor] eq $anchor} { lappend fifos [dict get $e fifo] }
        }
    }
    lock_release
    broadcast "reflow" $fifos
}

proc panel_exit {{rc 0}} {
    catch {after cancel $::timer}
    catch {after cancel $::clip_retire}
    if {$::clip_active} {
        set ::clip_active 0
        if {[selection own -selection PRIMARY] ne ""} {
            catch {selection clear -selection PRIMARY}
        }
    }
    if {$::panel_ch ne ""} {
        catch {fileevent $::panel_ch readable {}}
        catch {close $::panel_ch}
        set ::panel_ch ""
    }
    if {$::panel_fifo ne ""} { catch {file delete -force $::panel_fifo} }
    exit $rc
}

proc panel_close {} {
    if {$::closing} { return }
    set ::closing 1
    remove_self_and_broadcast
    catch {after cancel $::timer}
    if {$::clip_active} {
        catch {wm withdraw .}
        set ::visible 0
        if {$::clip_retire eq ""} {
            set ::clip_retire [after $::clip_ttl {panel_exit 0}]
        }
        return
    }
    panel_exit 0
}

proc panel_apply_config {conf} {
    if {$conf ne "" && ![file readable $conf]} { return 0 }

    set old [dict create]
    foreach k $::conf_keys { dict set old $k [set ::$k] }
    set old_conf $::panel_conf
    set old_sig $::panel_conf_sig

    reset_config
    load_config $conf
    if {[catch {font actual $::font} desc]} {
        dict for {k v} $old { set ::$k $v }
        set ::panel_conf $old_conf
        set ::panel_conf_sig $old_sig
        return 0
    }

    set ::panel_conf $conf
    set ::panel_conf_sig [conf_signature $conf]
    if {$::cli_duration ne ""} { set ::duration $::cli_duration }
    if {$::cli_min_show ne ""} { set ::min_show $::cli_min_show }
    set ::panel_min_show $::min_show

    if {$::visible} {
        catch {wm withdraw .}
        set ::visible 0
    }
    catch {destroy .l}
    catch {destroy .measure}
    catch {font delete ::osd_font}
    build_window
    render_text
    measure_self
    return 1
}

proc panel_update_from_file {path conf} {
    if {$::closing} { return }
    if {![file readable $path]} { return }
    if {[catch {set t [normalize_text [read_file $path]]}]} { return }
    catch {file delete -force $path}
    if {$t eq ""} { return }

    set ::text $t
    set changed [expr {$conf ne $::panel_conf || [conf_signature $conf] ne $::panel_conf_sig}]
    if {$changed} {
        if {![panel_apply_config $conf]} {
            render_text
            measure_self
        }
    } else {
        render_text
        measure_self
    }

    if {!$::visible} {
        wm deiconify .
        catch {wm attributes . -topmost 1}
        raise .
        set ::visible 1
    }
    update_self_entry
    reset_timer
}

proc panel_fifo_read {} {
    if {$::panel_ch eq ""} { return }
    if {[catch {read $::panel_ch} chunk]} { return }
    if {$chunk eq ""} { return }
    append ::panel_buf $chunk
    while {[set i [string first "\n" $::panel_buf]] >= 0} {
        set msg [string range $::panel_buf 0 [expr {$i - 1}]]
        set ::panel_buf [string range $::panel_buf [expr {$i + 1}] end]
        if {$msg eq ""} continue
        if {$msg eq "reflow"} {
            refresh_layout
        } elseif {$msg eq "close"} {
            panel_close
        } elseif {$msg eq "quit"} {
            remove_self_and_broadcast
            panel_exit 0
        } elseif {$msg eq "evict"} {
            set age [expr {[clock milliseconds] - $::panel_born}]
            set wait [expr {$::panel_min_show - $age}]
            if {$wait > 0} {
                after $wait {panel_close}
            } else {
                panel_close
            }
        } elseif {[lindex $msg 0] eq "update"} {
            set args [lrange $msg 1 end]
            set tp [lindex $args 0]
            set cp [expr {[llength $args] > 1 ? [lindex $args 1] : $::panel_conf}]
            panel_update_from_file $tp $cp
        }
    }
}

proc panel_create_fifo {} {
    set ::panel_fifo [file join $::fifos_dir $::panel_id]
    catch {file delete -force $::panel_fifo}
    if {[catch {exec mkfifo -m 600 $::panel_fifo} err]} {
        return -code error "не удалось создать FIFO: $err"
    }
    if {[catch {open $::panel_fifo {RDWR NONBLOCK}} ch]} {
        return -code error "не удалось открыть FIFO: $ch"
    }
    set ::panel_ch $ch
    fconfigure $ch -translation binary -blocking 0 -buffering none
    fileevent $ch readable panel_fifo_read
}

proc panel_main {opts} {
    set ack [dict get $opts ack]
    if {[catch {
        package require Tk
        set conf [dict get $opts config]
        load_config $conf
        set ::panel_conf $conf
        set ::panel_conf_sig [conf_signature $conf]
        if {[dict exists $opts duration] && [dict get $opts duration] ne ""} {
            set d [dict get $opts duration]
            if {![string is integer -strict $d] || $d < 0} {
                error "duration должен быть неотрицательным целым"
            }
            set ::duration $d
            set ::cli_duration $d
        }
        if {[dict exists $opts min_show] && [dict get $opts min_show] ne ""} {
            set ms [dict get $opts min_show]
            if {![string is integer -strict $ms] || $ms < 0} {
                error "min_show должен быть неотрицательным целым"
            }
            set ::min_show $ms
            set ::cli_min_show $ms
        }
        set ::panel_min_show $::min_show
        set pk [dict get $opts key]
        if {$pk eq ""} { set pk "default" }
        set ::panel_key $pk
        set ::panel_kind [dict get $opts kind]
        set pv [dict get $opts prio]
        if {![string is integer -strict $pv]} { error "prio должен быть целым" }
        set ::panel_prio $pv
        set sv [string tolower [dict get $opts sticky]]
        if {$sv in {1 true yes on}} {
            set ::panel_sticky 1
        } elseif {$sv eq "" || $sv in {0 false no off}} {
            set ::panel_sticky 0
        } else {
            error "sticky должен быть 0|1"
        }
        set ::panel_id [dict get $opts id]
        set ::panel_born [clock milliseconds]
        set ::clip_mode [clip_tool]

        set text_path [dict get $opts text_file]
        if {![file readable $text_path]} { error "текст не читается: $text_path" }
        set ::text [normalize_text [read_file $text_path]]
        catch {file delete -force $text_path}
        if {[string trim $::text] eq ""} { error "пустой текст" }

        if {$::allow_multiple == 0} {
            set target [find_reuse_target]
            if {$target ne ""} {
                set upd [file join $::spool_dir "upd-[pid]-[clock milliseconds]-[expr {int(rand()*1000000)}].txt"]
                atomic_write $upd $::text
                if {[fifo_send [dict get $target fifo] "update [list $upd $conf]"]} {
                    panel_ack $ack "ok"
                    exit 0
                }
                catch {file delete -force $upd}
                drop_panel_entry [dict get $target id]
            }
        }

        build_window
        render_text
        measure_self
        panel_create_fifo
        register_self
        place_at $::cur_y
        wm deiconify .
        catch {wm attributes . -topmost 1}
        raise .
        set ::visible 1
        reset_timer
        panel_ack $ack "ok"
    } err]} {
        panel_ack $ack "err $err"
        if {$::panel_path ne ""} { catch {remove_self_and_broadcast} }
        catch {file delete -force $::panel_fifo}
        exit 1
    }
    vwait ::forever
}

proc spawn_panel {conf text opts} {
    set id "[pid]-[clock milliseconds]-[expr {int(rand()*1000000)}]"
    regsub -all {[^A-Za-z0-9_.-]} $id _ id
    set text_path [file join $::spool_dir "text-$id.txt"]
    atomic_write $text_path $text
    set ack_path [file join $::spool_dir "ack-$id.txt"]

    set cmd [list [info nameofexecutable] $::script_file --panel \
        --id $id --text-file $text_path --ack $ack_path]
    if {$conf ne ""} { lappend cmd --config $conf }
    foreach k {key kind prio sticky duration min_show} {
        if {[dict exists $opts $k] && [dict get $opts $k] ne ""} {
            lappend cmd --$k [dict get $opts $k]
        }
    }

    set launcher {}
    if {[auto_execok setsid] ne ""} { set launcher [list setsid -f] }
    set full [concat $launcher $cmd]
    if {[catch {exec {*}$full < /dev/null > /dev/null 2> /dev/null &} err]} {
        catch {file delete -force $text_path}
        die "не удалось запустить плашку: $err" 1
    }

    set deadline [expr {[clock milliseconds] + 8000}]
    while {[clock milliseconds] < $deadline} {
        if {[file readable $ack_path]} {
            set res [string trim [read_file $ack_path]]
            catch {file delete -force $ack_path}
            if {[string match "ok*" $res]} { return 1 }
            catch {file delete -force $text_path}
            puts stderr "$::app: $res"
            return 0
        }
        after 20
    }
    puts stderr "$::app: плашка не подтвердила запуск"
    catch {file delete -force $ack_path}
    return 0
}

proc update_state {text opts conf} {
    set key [dict get $opts key]
    if {$key eq ""} { return 0 }
    if {[lock_acquire] == 0} { return 0 }
    set entries [lindex [sweep_dead_locked] 0]
    set target ""
    foreach e $entries {
        if {[dict get $e kind] eq "state" && [dict get $e key] eq $key} {
            set target $e
            break
        }
    }
    lock_release
    if {$target eq ""} { return 0 }
    set id [dict get $target id]
    set path [file join $::spool_dir "upd-[pid]-[clock milliseconds]-[expr {int(rand()*1000000)}].txt"]
    atomic_write $path $text
    if {[fifo_send [dict get $target fifo] "update [list $path $conf]"]} { return 1 }
    catch {file delete -force $path}
    return 0
}

proc close_all {} {
    set pids {}
    set fifos {}
    if {[lock_acquire] == 0} { return 0 }
    set entries [lindex [sweep_dead_locked] 0]
    foreach e $entries {
        lappend pids [dict get $e pid]
        lappend fifos [dict get $e fifo]
    }
    lock_release

    foreach f $fifos { fifo_send $f "quit" }

    set deadline [expr {[clock milliseconds] + 2000}]
    while {[clock milliseconds] < $deadline} {
        set alive 0
        foreach p $pids { if {[pid_is_osd $p]} { set alive 1 } }
        if {!$alive} break
        after 25
    }
    foreach p $pids {
        if {[pid_is_osd $p]} { catch {exec kill $p} }
    }

    if {[lock_acquire] != 0} {
        catch {sweep_dead_locked}
        lock_release
    }

    if {[file readable $::legacy_pid]} {
        set p [string trim [read_file $::legacy_pid]]
        if {[pid_is_osd $p]} { catch {exec kill $p} }
        catch {file delete -force $::legacy_pid}
    }
    catch {file delete -force $::legacy_fifo}
    return 1
}

proc parse_args {argv} {
    set o [dict create config "" file "" use_stdin 0 text_args {} \
        dump 0 kill 0 panel 0 daemon 0 end 0 key "" kind "event" \
        prio 0 sticky 0 duration "" min_show "" id "" text_file "" ack ""]
    set n [llength $argv]
    for {set i 0} {$i < $n} {incr i} {
        set a [lindex $argv $i]
        if {[dict get $o end] == 0 && $a eq "--"} {
            dict set o end 1
            continue
        }
        if {[dict get $o end] == 0 && $a eq "-"} {
            dict set o use_stdin 1
            continue
        }
        if {[dict get $o end] == 0} {
            switch -- $a {
                -h - --help { help }
                --dump     { dict set o dump 1; continue }
                --kill     { dict set o kill 1; continue }
                --daemon   { dict set o daemon 1; continue }
                --panel    { dict set o panel 1; continue }
                -f - --file {
                    incr i
                    if {$i >= $n} { usage "не указан путь к файлу" }
                    dict set o file [lindex $argv $i]
                    continue
                }
                --config {
                    incr i
                    if {$i >= $n} { usage "не указан путь к конфигу" }
                    dict set o config [lindex $argv $i]
                    continue
                }
                --key - --kind - --prio - --sticky - --duration - --min-show - --min_show - --id - --text-file - --ack {
                    incr i
                    if {$i >= $n} { usage "не указано значение для $a" }
                    set v [lindex $argv $i]
                    switch -- $a {
                        --key        { dict set o key $v }
                        --kind       { dict set o kind $v }
                        --prio       { dict set o prio $v }
                        --sticky     { dict set o sticky $v }
                        --duration   { dict set o duration $v }
                        --min-show   { dict set o min_show $v }
                        --min_show   { dict set o min_show $v }
                        --id         { dict set o id $v }
                        --text-file  { dict set o text_file $v }
                        --ack        { dict set o ack $v }
                    }
                    continue
                }
            }
        }
        if {[dict get $o end] == 0 && [string index $a 0] eq "-"} {
            usage "неизвестная опция: $a"
        }
        dict lappend o text_args $a
    }
    return $o
}

proc client_main {o} {
    if {[dict get $o kill]} {
        close_all
        exit 0
    }
    set text [collect_text [dict get $o file] [dict get $o use_stdin] {*}[dict get $o text_args]]
    if {$text eq "" || [string trim $text] eq ""} {
        die "пустой текст" 2
    }
    if {[dict get $o dump]} {
        puts $text
        exit 0
    }
    set conf [resolve_config [dict get $o config]]
    set kind [string tolower [dict get $o kind]]
    if {$kind ni {state event}} { die "kind должен быть state или event" 2 }
    dict set o kind $kind

    if {$kind eq "state" && [dict get $o key] ne ""} {
        if {[update_state $text $o $conf]} { exit 0 }
    }
    if {![spawn_panel $conf $text $o]} { exit 1 }
    exit 0
}

proc main {} {
    set o [parse_args $::argv]
    set_paths
    if {[dict get $o panel]} {
        panel_main $o
        return
    }
    if {[dict get $o daemon]} {
        puts stderr "$::app: --daemon больше не нужен: постоянного демона нет"
        exit 0
    }
    client_main $o
}

main
