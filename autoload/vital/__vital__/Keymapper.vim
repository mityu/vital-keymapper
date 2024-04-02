const s:state = {
  \ 'done': 1,
  \ 'pending': 2,
  \}

let s:module = {
  \ '_input_queue': [],
  \ '_mode': '',
  \ '_modes': {},
  \ 'state': s:state,
  \}

function s:new() abort
  return deepcopy(s:module)
endfunction

" Adds a {mode} and set options for the {mode}.  Do nothing when {mode} is
" already exists.
function s:module.add_mode(mode, opts = {}) abort
  if !has_key(self._modes, a:mode)
    let opts = {'handle_count': 1}
    for [k, v] in items(a:opts)
      call s:_set_option(opts, k, v)
    endfor
    let self._modes[a:mode] = {'maptree': {}, 'opts': opts}
  endif
endfunction

function s:module.remove_mode(mode) abort
  if !has_key(self._modes, a:mode)
    throw 'vital: Keymapper: mode not found: ' . a:mode
    return
  endif
  call remove(self._modes, a:mode)
endfunction

function s:module.set_mode(mode) abort
  if !has_key(self._modes, a:mode)
    throw 'vital: Keymapper: mode not found: ' . a:mode
    return
  endif
  let self._mode = a:mode
endfunction

function s:module.add_mapping(mode, lhs, rhs, opt = {}) abort
  if !has_key(self._modes, a:mode)
    throw 'vital: Keymapper: mode not found: ' . a:mode
    return
  endif
  let remap = get(a:opt, 'remap', 0)
  call s:_add_mapping(self._modes[a:mode].maptree, a:lhs, a:rhs, remap)
endfunction

function s:module.remove_mapping(mode, lhs) abort
  if !has_key(self._modes, a:mode)
    throw 'vital: Keymapper: mode not found: ' . a:mode
    return
  endif
  call s:_remove_mapping(self._modes[a:mode].maptree, a:lhs)
endfunction

" set_mode_options({mode}, {opts})
" set_mode_options({mode}, {key}, {value})
function s:module.set_mode_options(mode, ...) abort
  if !has_key(self._modes, a:mode)
    throw 'vital: Keymapper: mode not found: ' . a:mode
  elseif !has_key(self._modes[a:mode].opts, a:opt)
    throw 'vital: Keymapper: mode-option not found: ' . a:opt
  else
    let opts = self._modes[a:mode].opts
    if len(a:000) == 1
      for [k, v] in items(a:1)
        call s:_set_option(opts, k, v)
      endfor
    else
      call s:_set_option(opts, a:1, a:2)
    endif
  endif
endfunction

" Append keys at the end of input queue.  {keys} is treated in the same way
" that feedkeys() does.  In other words, use "\<ESC>" to add escape key.
" '<ESC>' means the character sequence of '<', 'E', 'S', 'C', and '>'.
function s:module.append_keys(keys) abort
  let self._input_queue += s:_split_into_keyseq(s:_keytrans(a:keys))
endfunction

function s:module.lookup_mapping(timeouted = 0)
  if !has_key(self._modes, self._mode)
    throw 'vital: Keymapper: mode not found: ' . self._mode
    return
  endif
  const mode = self._modes[self._mode]
  const [result, input_queue] = s:_lookup_mapping(
    \ mode.maptree, self._input_queue, mode.opts.handle_count, a:timeouted)
  let self._input_queue = input_queue
  return result
endfunction


function s:_replace_termcodes(keys) abort
  return substitute(a:keys, '<[^<>]\+>',
   \ '\=eval(printf(''"\%s"'', submatch(0)))', 'g')
endfunction

" Same as builtin keytrans(), but leave <Nop> as it is.
function s:_keytrans(keys) abort
  return join(map(split(a:keys, '\c<Nop>', 1), 'keytrans(v:val)'), '<Nop>')
endfunction

" Convert keys into the form which can be used with :map.
function s:_regularize_keys(keys) abort
  return s:_keytrans(s:_replace_termcodes(a:keys))
endfunction

function s:_split_into_keyseq(keys) abort
  return split(a:keys, '\%(<[^<>]\+>\|.\)\zs')
endfunction

function s:_separate_count_and_map(seq) abort
  return matchlist(a:seq, '^\v(\d+)?(.*)$')[1 : 2]
endfunction

function s:_add_mapping(maptree, lhs, rhs, remap) abort
  let lhs = s:_split_into_keyseq(s:_regularize_keys(a:lhs))

  if empty(lhs)
    throw 'vital: Keymapper: {lhs} is empty'
    return
  endif

  let tree = a:maptree
  for c in lhs
    if !has_key(tree, c)
      let tree[c] = {}
    endif
    let tree = tree[c]
  endfor

  let mapto = s:_regularize_keys(a:rhs)
  if mapto ==? '<Nop>'
    let mapto = ''
  endif

  let tree.rhs = {'mapto': mapto, 'remap': a:remap}
endfunction

function s:_remove_mapping(maptree, lhs) abort
  let lhs = s:_split_into_keyseq(s:_regularize_keys(a:lhs))

  if empty(lhs)
    throw 'vital: Keymapper: {lhs} is empty'
    return
  endif

  let tree = a:maptree
  let node_to_remove = []
  for c in lhs
    if !has_key(tree, c)
      throw 'vital: Keymapper: No mappings found for: ' . a:lhs
      return
    endif

    let parent = tree
    let tree = tree[c]
    if len(tree) > 1
      let node_to_remove = []
    elseif empty(node_to_remove)
      let node_to_remove = [parent, c]
    endif
  endfor

  if !has_key(tree, 'rhs')
    throw 'vital: Keymapper: No mappings found for: ' . a:lhs
    return
  endif

  if empty(node_to_remove)
    call remove(tree, 'rhs')
  else
    call remove(node_to_remove[0], node_to_remove[1])
  endif
endfunction

" @param {dict<any>} maptree
" @param {list<string>} input_queue characterwisely separated list of input characters.
" @param {boolean} handle_count TRUE if handle {count}.
" @param {boolean} timeouted TRUE for no more pending is needed.
function s:_lookup_mapping(maptree, input_queue, handle_count, timeouted) abort
  let mapdepth = 0
  let keys = copy(a:input_queue)
  let cnt = ''
  const result_pending = [{
    \ 'state': s:state.pending,
    \ 'resolved': '',
    \ 'count': 0,
    \ 'count1': 1,
    \}, a:input_queue]

  while 1
    let tree = a:maptree
    let entire_keys = copy(keys)
    let may_rhs = []
    let processed_keys = []

    while !empty(keys)
      if !has_key(tree, keys[0])
        break
      endif

      let c = remove(keys, 0)
      let tree = tree[c]
      call add(processed_keys, c)
      if has_key(tree, 'rhs')
        let may_rhs = [tree.rhs, join(processed_keys, '')]
      endif
    endwhile

    let rhs = {}
    if a:timeouted || get(keys, 0, '') ==# '<Ignore>'
      if !empty(may_rhs)
        let rhs = may_rhs[0]
        let keys = copy(entire_keys[strlen(may_rhs[1]) :])
      else
        let keys = processed_keys + keys
        if a:handle_count && keys[0] =~# '\d'
          let cnt .= remove(keys, 0)
          if empty(keys)
            " Throw away {count}.
            return [result_pending[0], []]
          else
            continue
          endif
        elseif keys[0] ==# '<Ignore>'
          call remove(keys, 0)
          if empty(keys)
            " Throw away {count}.
            return [result_pending[0], []]
          else
            continue
          endif
        else
          let rhs = {'mapto': remove(keys, 0), 'remap': 0}
        endif
      endif
    else
      if empty(keys)
        if has_key(tree, 'rhs') && len(tree) == 1
          let rhs = tree.rhs
        else
          return result_pending
        endif
      elseif has_key(tree, 'rhs')
        let rhs = tree.rhs
      else
        let keys = processed_keys + keys
        if a:handle_count && keys[0] =~# '\d'
          let cnt .= remove(keys, 0)
          if empty(keys)
            return result_pending
          else
            continue
          endif
        else
          let rhs = {'mapto': remove(keys, 0), 'remap': 0}
        endif
      endif
    endif

    if !rhs.remap
      if a:handle_count
        let [mapto_cnt, rhs.mapto] = s:_separate_count_and_map(rhs.mapto)
        let cnt .= mapto_cnt
      endif
      let cntnr = str2nr(cnt)
      return [{
        \ 'state': s:state.done,
        \ 'resolved': rhs.mapto,
        \ 'count': cntnr,
        \ 'count1': cntnr ? cntnr : 1,
        \}, keys]
    else
      " Resolve remapping
      let keys = s:_split_into_keyseq(rhs.mapto) + keys
      let mapdepth += 1
      if mapdepth > &maxmapdepth
        throw 'vital: Keymapper: Recursive mapping'
      endif
    endif
  endwhile
endfunction

function s:_set_option(opts, key, value) abort
  if !has_key(a:opts, a:key)
    throw 'vital: Keymapper: option not found: ' . a:key
  endif
  let a:opts[a:key] = a:value
endfunction
