vim9script

#"
# This variable is used to inform the s:step_*() functions about whether the
# current movement is a cursor movement or a scroll movement.  Used for
# motions like gg and G
var cursor_movement = false
var timer_id: number
var now_moving = false

g:scroll_called = 0

# This variable is needed to the s:step_down() function know whether to
# continue scrolling after reaching EOL (as in ^F) or not (^B, ^D, ^U, etc.)
#
# NOTE: This variable "MUST" be set to false in "every" function that
# invokes motion (except smoothie#forwards, where it must be set to true)
var ctrl_f_invoked = false

if !exists('g:smoothie_enabled')
  #"
  # Set it to 0 to disable vim-smoothie.  Useful for very slow connections.
  g:smoothie_enabled = 1
endif

if !exists('g:smoothie_update_interval')
  #"
  # Time (in milliseconds) between subsequent screen/cursor position updates.
  # Lower value produces smoother animation.  Might be useful to increase it
  # when running Vim over low-bandwidth/high-latency connections.
  g:smoothie_update_interval = 20
endif

if !exists('g:smoothie_speed_constant_factor')
  #"
  # This value controls constant term of the velocity curve. Increasing this
  # boosts primarily cursor speed at the end of animation.
  g:smoothie_speed_constant_factor = 10
endif

if !exists('g:smoothie_speed_linear_factor')
  #"
  # This value controls linear term of the velocity curve. Increasing this
  # boosts primarily cursor speed at the beginning of animation.
  g:smoothie_speed_linear_factor = 10
endif

if !exists('g:smoothie_speed_exponentiation_factor')
  #"
  # This value controls exponent of the power function in the velocity curve.
  # Generally should be less or equal to 1.0. Lower values produce longer but
  # perceivably smoother animation.
  g:smoothie_speed_exponentiation_factor = 0.9
endif

if !exists('g:smoothie_break_on_reverse')
  #"
  # Stop immediately if we're moving and the user requested moving in opposite
  # direction.  It's mostly useful at very low scrolling speeds, hence
  # disabled by default.
  g:smoothie_break_on_reverse = 0
endif

#"
# Execute {command}, but saving 'scroll' value before, and restoring it
# afterwards.  Useful for some commands (such as ^D or ^U), which overwrite
# 'scroll' permanently if used with a [count].
#
# Additionally, this function temporarily clears 'scrolloff' and resets it
# after command execution. This is workaround for a bug described in
# https://github.com/psliwka/vim-smoothie/issues/18
def s:execute_preserving_scroll(command: string)
  var saved_scroll = &scroll
  execute command
  &scroll = saved_scroll
enddef

#"
# Scroll the window up by one line, or move the cursor up if the window is
# already at the top.  Return 1 if cannot move any higher.
def s:step_up(): bool
  if line('.') > 1
    if s:cursor_movement
      exe 'normal! k'
      return 0
    endif
    s:execute_preserving_scroll("normal! 1\<C-U>")
    return 0
  else
    return 1
  endif
enddef

#"
# Scroll the window down by one line, or move the cursor down if the window is
# already at the bottom.  Return 1 if cannot move any lower.
def s:step_down(): bool
  var initial_winline = winline()

  if line('.') < line('$')
    if s:cursor_movement
      exe 'normal! j'
      return 0
    endif
    # NOTE: the three lines of code following this comment block
    # have been implemented as a temporary workaround for a vim issue
    # regarding Ctrl-D and folds.
    #
    # See: neovim/neovim#13080
    if foldclosedend('.') != -1
      cursor(foldclosedend('.'), col('.'))
    endif
    s:execute_preserving_scroll("normal! 1\<C-D>")
    if ctrl_f_invoked && winline() > initial_winline
      # ^F is pressed, and the last motion caused cursor postion to change
      # scroll window to keep cursor position fixed
      s:execute_preserving_scroll("normal! \<C-E>")
    endif
    return 0

  elseif ctrl_f_invoked && winline() > 1
    # cursor is already on last line of buffer, but not on last line of window
    # ^F can scroll more
    s:execute_preserving_scroll("normal! \<C-E>")
    return 0

  else
    return 1
  endif
enddef

#"
# Perform as many steps up or down to move {lines} lines from the starting
# position (negative {lines} value means to go up).  Return 1 if hit either
# top or bottom, and cannot move further.
def s:step_many(lines: number): bool
  var remaining_lines = lines
  while 1
    if remaining_lines < 0
      if s:step_up()
        return 1
      endif
      remaining_lines += 1
    elseif remaining_lines > 0
      if s:step_down()
        return 1
      endif
      remaining_lines -= 1
    else
      return 0
    endif
  endwhile
  return 0
enddef

#"
# A Number indicating how many lines do we need yet to move down (or up, if
# it's negative), to achieve what the user wants.
s:target_displacement = 0

#"
# A Float between -1.0 and 1.0 keeping our position between integral lines,
# used to make the animation smoother.
s:subline_position = 0.0

#"
# Start the animation timer if not already running.  Should be called when
# updating the target, when there's a chance we're not already moving.
def s:start_moving()
  if ((s:target_displacement < 0) ? line('.') == 1 : (line('.') == line('$') && (ctrl_f_invoked ? winline() == 1 : true)))
    # Invalid command
    s:ring_bell()
  endif
  if !now_moving
    s:timer_id = timer_start(g:smoothie_update_interval, function('s:movement_tick'), {'repeat': -1})
    now_moving = true
  endif
enddef

#"
# Stop any movement immediately, and disable the animation timer to conserve
# power.
def s:stop_moving()
  s:target_displacement = 0
  s:subline_position = 0.0
  if now_moving
   timer_stop(s:timer_id)
   now_moving = false
  endif
enddef

#"
# Calculate optimal movement velocity (in lines per second, negative value
# means to move upwards) for the next animation frame.
#
# TODO: current algorithm is rather crude, would be good to research better
# alternatives.
def s:compute_velocity(): float
  var absolute_speed = g:smoothie_speed_constant_factor + g:smoothie_speed_linear_factor * pow(abs(s:target_displacement - s:subline_position), g:smoothie_speed_exponentiation_factor)
  if s:target_displacement < 0
    return -absolute_speed
  else
    return absolute_speed
  endif
enddef

#"
# Execute single animation frame.  Called periodically by a timer.  Accepts a
# throwaway parameter: the timer ID.
def s:movement_tick(timer_id: number)
  if s:target_displacement == 0
    s:stop_moving()
    return
  endif

  var subline_step_size = s:subline_position + (g:smoothie_update_interval / 1000.0 * s:compute_velocity())
  var step_size = float2nr(trunc(subline_step_size))

  if abs(step_size) > abs(s:target_displacement)
    # clamp step size to prevent overshooting the target
    step_size = s:target_displacement
  end

  if s:step_many(step_size)
    # we've collided with either buffer end
    s:stop_moving()
  else
    s:target_displacement -= step_size
    s:subline_position = subline_step_size - step_size
  endif

  if step_size > 0
    # Usually Vim handles redraws well on its own, but without explicit redraw
    # I've encountered some sporadic display artifacts.  TODO: debug further.
    redraw
  endif
enddef

#"
# Set a new target where we should move to (in lines, relative to our current
# position).  If we're already moving, try to do the smart thing, taking into
# account our progress in reaching the target set previously.
def s:update_target(lines: number)
  if g:smoothie_break_on_reverse && s:target_displacement * lines < 0
    s:stop_moving()
  else
    # Cursor movements are very delicate. Since the displacement for cursor
    # movements is calulated from the "current" line, so immediately stop
    # moving, otherwise we will end up at the wrong line.
    if s:cursor_movement
      s:stop_moving()
    endif
    s:target_displacement += lines
    s:start_moving()
  endif
enddef

#"
# Helper function to calculate the actual number of screen lines from a line
# to another.  Useful for properly handling folds in case of cursor movements.
def s:calculate_screen_lines(from: number, to: number)
  from = from
  to = to
  from = (foldclosed(from) != -1 ? foldclosed(from) : from)
  to = (foldclosed(to) != -1 ? foldclosed(to) : to)
  if from == to
    return 0
  endif
  lines = 0
  linenr = from
  while linenr != to
    if linenr < to
      lines +=1
      linenr = (foldclosedend(linenr) != -1 ? foldclosedend(linenr) : linenr)
      linenr += 1
    elseif linenr > to
      lines -= 1
      linenr = (foldclosed(linenr) != -1 ? foldclosed(linenr) : linenr)
      linenr -= 1
    endif
  endwhile
  return lines
enddef

#"
# Helper function to set 'scroll' to [count], similarly to what native ^U and
# ^D commands do.
def s:count_to_scroll()
  if v:count
    &scroll = v:count
  end
enddef

#"
# Helper function to ring bell.
def s:ring_bell()
  #if !(&belloff =~# 'all\|error')
  #  belloff = &belloff
  #  set belloff=
  #  exe "normal \<Esc>"
  #  &belloff = belloff
  #endif
enddef

#"
# Smooth equivalent to ^D.
def smoothie#downwards()
  if !g:smoothie_enabled
    exe "normal! \<C-d>"
    return
  endif
  ctrl_f_invoked = false
  s:count_to_scroll()
  s:update_target(&scroll)
enddef

#"
# Smooth equivalent to ^U.
def smoothie#upwards()
  if !g:smoothie_enabled
    exe "normal! \<C-u>"
    return
  endif
  ctrl_f_invoked = false
  s:count_to_scroll()
  s:update_target(-&scroll)
enddef

#"
# Smooth equivalent to ^F.
def smoothie#forwards()
  if !g:smoothie_enabled
    exe "normal! \<C-f>"
    return
  endif
  ctrl_f_invoked = true
  s:update_target(winheight(0) * v:count1)
enddef

#"
# Smooth equivalent to ^B.
def smoothie#backwards()
  if !g:smoothie_enabled
    exe "normal! \<C-b>"
    return
  endif
  ctrl_f_invoked = false
  s:update_target(-winheight(0) * v:count1)
enddef

#"
# Smoothie equivalent for G and gg
# NOTE: I have also added - movement to dempnstrate how to add more new
#       movements in the future
def smoothie#cursor_movement(movement: string)
  movements = {
        \'gg': {
                \'target_expr':   'v:count1',
                \'startofline':   &startofline,
                \'jump_commmand': true,
                \},
        \'G' :  {
                \'target_expr':   "(v:count ? v:count : line('$'))",
                \'startofline':   &startofline,
                \'jump_commmand': true,
                \},
        \'-' :  {
                \'target_expr':   "line('.') - v:count1",
                \'startofline':   true,
                \'jump_commmand': false,
                \},
        \}
  if !has_key(movements, movement)
    return 1
  endif
  s:do_vertical_cursor_movement(movement, movements[movement])
enddef

#"
# Helper function to preform cursor movements
def s:do_vertical_cursor_movement(movement: string, properties: dict<any>)
  s:cursor_movement = true
  ctrl_f_invoked = false
  # If in operator pending mode, disable vim-smoothie and use the normal
  # non-smoothie version of the movement
  if !g:smoothie_enabled || mode(1) =~# 'o' && mode(1) =~? 'no'
    # If in operator-pending mode, prefer the movement to be linewise
    exe 'normal! ' . (mode(1) ==# 'no' ? 'V' : '') . v:count . movement
    return
  endif
  target = eval(properties['target_expr'])
  target = (target > line('$') ? line('$') : target)
  target = (foldclosed(target) != -1 ? foldclosed(target) : target)
  if foldclosed('.') == target
    s:cursor_movement = false
    return
  endif
  # if this is a jump command, append current position to the jumplist
  if properties['jump_commmand']
    execute "normal! m'"
  endif
  s:update_target(s:calculate_screen_lines(line('.'), target))
  # suspend further commands till the destination is reached
  # see point (3) of https://github.com/psliwka/vim-smoothie/issues/1#issuecomment-560158642
  while line('.') != target
    exe 'sleep ' . g:smoothie_update_interval . ' m'
  endwhile
  s:cursor_movement = false   " reset s:cursor_movement to false
  if properties['startofline']
    # move cursor to the first non-blank character of the line
    cursor(line('.'), match(getline('.'),'\S')+1)
  endif
enddef

# vim: et ts=2
