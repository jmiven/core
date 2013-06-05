open Std_internal

module Unix = Core_unix

let concat = String.concat

let log string a sexp_of_a =
  Printf.eprintf "%s\n%!"
    (Sexp.to_string_hum (<:sexp_of< string * a  >> (string, a)));
;;

module Make (M : sig end) = struct

  let check_invariant = ref true

  let show_messages = ref true

  open Iobuf

  type nonrec ('d, 'w) t = ('d, 'w) t with sexp_of
  type nonrec no_seek = no_seek with sexp_of
  type nonrec seek = seek with sexp_of

  let invariant = invariant

  let debug name ts arg sexp_of_arg sexp_of_result f =
    let prefix = "Iobuf." in
    if !show_messages then log (concat [ prefix; name ]) arg sexp_of_arg;
    if !check_invariant then List.iter ts ~f:(invariant ignore ignore);
    let result_or_exn = Result.try_with f in
    if !show_messages then
      log (concat [ prefix; name; " result" ]) result_or_exn
        (<:sexp_of< (result, exn) Result.t >>);
    if !check_invariant then List.iter ts ~f:(invariant ignore ignore);
    Result.ok_exn result_or_exn;
  ;;

  let create ~len =
    debug "create" [] (`len len)
      (<:sexp_of< [ `len of int ] >>)
      (<:sexp_of< (_, _) t >>)
      (fun () ->
         let t = create ~len in
         if !check_invariant then invariant ignore ignore t;
         t)
  ;;

  let capacity t =
    debug "capacity" [t] t <:sexp_of< (_, _) t >> sexp_of_int (fun () -> capacity t)
  ;;

  let of_bigstring ?pos ?len bigstring =
    debug "of_bigstring" []
      (`pos pos, `len len, `bigstring_len (Bigstring.length bigstring))
      (<:sexp_of< ([ `pos of int option ]
                   * [ `len of int option ]
                   * [ `bigstring_len of int ]) >>)
      (<:sexp_of< (_, _) t >>)
      (fun () ->
        let t = of_bigstring ?pos ?len bigstring in
        if !check_invariant then invariant ignore ignore t;
        t)
  ;;

  let length t =
    debug "length" [t] t <:sexp_of< (_, _) t >> sexp_of_int (fun () -> length t)
  ;;
  let is_empty t =
    debug "is_empty" [t] t <:sexp_of< (_, _) t >> sexp_of_bool (fun () -> is_empty t)
  ;;

  module Snapshot = struct
    let restore t iobuf =
      debug "Snapshot.restore" [iobuf] t Snapshot.sexp_of_t sexp_of_unit (fun () ->
        Snapshot.restore t iobuf)

    type t = Snapshot.t with sexp_of
  end

  let snapshot t =
    debug "snapshot" [t] t <:sexp_of< (_, _) t >> <:sexp_of< Snapshot.t >> (fun () ->
      snapshot t)
  ;;

  let rewind t =
    debug "rewind" [t] t <:sexp_of< (_, _) t >> sexp_of_unit (fun () -> rewind t)
  ;;
  let reset t =
    debug "reset" [t] t <:sexp_of< (_, _) t >> sexp_of_unit (fun () -> reset t)
  ;;

  let flip t =
    debug "flip" [t] t <:sexp_of< (_, _) t >> sexp_of_unit (fun () -> flip t)
  ;;
  let compact t =
    debug "compact" [t] t <:sexp_of< (_, _) t >> sexp_of_unit (fun () -> compact t)
  ;;
  let sub ?pos ?len t =
    debug "sub" [t] (`pos pos, `len len)
      <:sexp_of< [ `pos of int option ] * [ `len of int option ] >>
      <:sexp_of< (_, _) t >>
      (fun () -> sub ?pos ?len t)
  ;;
  let narrow t =
    debug "narrow" [t] t <:sexp_of< (_, _) t >> sexp_of_unit (fun () -> narrow t)
  ;;
  let resize t ~len =
    debug "resize" [t] (`len len) <:sexp_of< [ `len of int ] >> sexp_of_unit (fun () ->
      resize t ~len)
  ;;

  let of_string s =
    debug "of_string" []
      s <:sexp_of< string >> <:sexp_of< (_, _) t >>
      (fun () ->
        let t = of_string s in
        if !check_invariant then invariant ignore ignore t;
        t)
  ;;

  let to_string ?len t =
    debug "to_string" [t]
      (`len len) <:sexp_of< [ `len of int option ] >> <:sexp_of< string >>
      (fun () -> to_string ?len t)
  ;;

  let advance t i = debug "advance" [t] i sexp_of_int sexp_of_unit (fun () -> advance t i)

  let debug_range name f =
    fun ?pos ?len t buf ->
      debug name [t] (`pos pos, `len len)
        (<:sexp_of< [ `pos of int option ] * [ `len of int option ] >>)
        (<:sexp_of< unit >>)
        (fun () -> f ?pos ?len t buf)
  ;;

  let consume_into_string ?pos =
    debug_range "consume_into_string" consume_into_string ?pos
  let consume_into_bigstring ?pos =
    debug_range "consume_into_bigstring" consume_into_bigstring ?pos

  module Consume = struct
    let d name f sexp_of_result t =
      debug ("Consume." ^ name) [t] t <:sexp_of< (_, seek) t >> sexp_of_result (fun () ->
        f t)
    ;;

    open Consume

    type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

    let char        t = d "char"        char        sexp_of_char  t
    let  int8       t = d  "int8"        int8       sexp_of_int   t
    let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
    let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
    let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
    let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
    let uint8       t = d "uint8"       uint8       sexp_of_int   t
    let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
    let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
    let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
    let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
    let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
    let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
    let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
    let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

    let padded_fixed_string ~padding ~len t =
      debug "Consume.padded_fixed_string" [t] (`padding padding, `len len)
        <:sexp_of< [ `padding of char ] * [ `len of int ] >>
        sexp_of_string
        (fun () -> padded_fixed_string ~padding ~len t)

    let string ?str_pos ?len t =
      debug "Consume.string" [t] (`str_pos str_pos, `len len)
        <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] >>
        sexp_of_string
        (fun () -> string ?str_pos ?len t)

    let bigstring ?str_pos ?len t =
      debug "Consume.bigstring" [t] (`str_pos str_pos, `len len)
        <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] >>
        sexp_of_bigstring
        (fun () -> bigstring ?str_pos ?len t)
  end

  module Fill = struct
    let d name f sexp_of_arg t arg =
      debug ("Fill." ^ name) [t] arg sexp_of_arg sexp_of_unit (fun () ->
        f t arg)
    ;;

    open Fill

    type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

    let char        t = d "char"        char        sexp_of_char  t
    let  int8       t = d  "int8"        int8       sexp_of_int   t
    let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
    let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
    let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
    let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
    let uint8       t = d "uint8"       uint8       sexp_of_int   t
    let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
    let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
    let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
    let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
    let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
    let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
    let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
    let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

    let padded_fixed_string ~padding ~len t str =
      debug "Fill.padded_fixed_string" [t] (`padding padding, `len len, str)
        <:sexp_of< [ `padding of char ] * [ `len of int ] * string >>
        sexp_of_unit
        (fun () -> padded_fixed_string ~padding ~len t str)

    let string ?str_pos ?len t str =
      debug "Fill.string" [t] (`str_pos str_pos, `len len, str)
        <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] * string >>
        sexp_of_unit
        (fun () -> string ?str_pos ?len t str)

    let bigstring ?str_pos ?len t str =
      debug "Fill.bigstring" [t] (`str_pos str_pos, `len len, str)
        <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] * bigstring >>
        sexp_of_unit
        (fun () -> bigstring ?str_pos ?len t str)
  end

  module Peek = struct
    let d name f sexp_of_result t ~pos =
      debug ("Peek." ^ name)
        [t]
        (`pos pos)
        <:sexp_of< [ `pos of int ] >>
        sexp_of_result
        (fun () -> f t ~pos)
    ;;

    open Peek

    type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

    let char        t = d "char"        char        sexp_of_char  t
    let  int8       t = d  "int8"        int8       sexp_of_int   t
    let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
    let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
    let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
    let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
    let uint8       t = d "uint8"       uint8       sexp_of_int   t
    let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
    let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
    let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
    let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
    let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
    let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
    let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
    let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

    let padded_fixed_string ~padding ~len t ~pos =
      debug "Peek.padded_fixed_string" [t] (`padding padding, `len len, `pos pos)
        <:sexp_of< [ `padding of char ] * [ `len of int ] * [ `pos of int ] >>
        sexp_of_string
        (fun () -> padded_fixed_string ~padding ~len t ~pos)

    let string ?str_pos ?len t ~pos =
      debug "Peek.string" [t] (`str_pos str_pos, `len len, `pos pos)
        <:sexp_of< [ `str_pos of int option ]
                  * [ `len of int option ]
                  * [ `pos of int ] >>
        sexp_of_string
        (fun () -> string ?str_pos ?len t ~pos)

    let bigstring ?str_pos ?len t ~pos =
      debug "Peek.bigstring" [t] (`str_pos str_pos, `len len, `pos pos)
        <:sexp_of< [ `str_pos of int option ]
                  * [ `len of int option ]
                  * [ `pos of int ] >>
        sexp_of_bigstring
        (fun () -> bigstring ?str_pos ?len t ~pos)
  end
  module Poke = struct
    let d name f sexp_of_arg t ~pos arg =
      debug ("Poke." ^ name)
        [t]
        (`pos pos, arg)
        (Tuple.T2.sexp_of_t <:sexp_of< [ `pos of int ] >> sexp_of_arg)
        sexp_of_unit
        (fun () -> f t ~pos arg)
    ;;

    open Poke

    type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

    let char        t = d "char"        char        sexp_of_char  t
    let  int8       t = d  "int8"        int8       sexp_of_int   t
    let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
    let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
    let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
    let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
    let uint8       t = d "uint8"       uint8       sexp_of_int   t
    let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
    let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
    let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
    let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
    let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
    let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
    let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
    let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

    let padded_fixed_string ~padding ~len t ~pos str =
      debug "Poke.padded_fixed_string" [t]
        (`padding padding, `len len, `pos pos, str)
        <:sexp_of< [ `padding of char ] * [ `len of int ] * [ `pos of int ] * string >>
        sexp_of_unit
        (fun () -> padded_fixed_string ~padding ~len t ~pos str)

    let string ?str_pos ?len t ~pos str =
      debug "Poke.string" [t] (`str_pos str_pos, `len len, `pos pos, str)
        <:sexp_of< [ `str_pos of int option ]
                  * [ `len of int option ]
                  * [ `pos of int ]
                  * string >>
        sexp_of_unit
        (fun () -> string ?str_pos ?len t ~pos str)

    let bigstring ?str_pos ?len t ~pos str =
      debug "Poke.bigstring" [t] (`str_pos str_pos, `len len, `pos pos, str)
        <:sexp_of< [ `str_pos of int option ]
                  * [ `len of int option ]
                  * [ `pos of int ]
                  * bigstring >>
        sexp_of_unit
        (fun () -> bigstring ?str_pos ?len t ~pos str)
  end

  let consume_bin_prot t r =
    debug "consume_bin_prot" [t] t <:sexp_of< (_, _) t >>
      <:sexp_of< _ Or_error.t >>
      (fun () -> consume_bin_prot t r)
  ;;

  let fill_bin_prot t w a =
    debug "fill_bin_prot" [t] t <:sexp_of< (_, _) t >>
      <:sexp_of< unit Or_error.t >>
      (fun () -> fill_bin_prot t w a)
  ;;

  let transfer ?len ~src ~dst =
    debug "transfer" [src] (`len len)
      <:sexp_of< [ `len of int option ] >>
      sexp_of_unit
      (fun () ->
        (* Check dst's invariant separately because it has a different type. *)
        let finally () = if !check_invariant then invariant ignore ignore dst in
        finally ();
        protect ~finally ~f:(fun () -> transfer ?len ~src ~dst))
  ;;

  let memmove t ~src_pos ~dst_pos ~len =
    debug "memmove" [t] (`src_pos src_pos, `dst_pos dst_pos, `len len)
      (<:sexp_of< [`src_pos of int] * [`dst_pos of int] * [`len of int] >>)
      (<:sexp_of< unit >>)
      (fun () -> memmove t ~src_pos ~dst_pos ~len)
  ;;

  module File_descr = Unix.File_descr

  let read_assume_fd_is_nonblocking t fd =
    debug "read_assume_fd_is_nonblocking" [t] fd
      (<:sexp_of< File_descr.t >>)
      (<:sexp_of< int >>)
      (fun () -> read_assume_fd_is_nonblocking t fd)
  ;;

  let pread_assume_fd_is_nonblocking t fd ~offset =
    debug "pread_assume_fd_is_nonblocking" [t] (fd, `offset offset)
      (<:sexp_of< File_descr.t * [ `offset of int ] >>)
      (<:sexp_of< int >>)
      (fun () -> pread_assume_fd_is_nonblocking t fd ~offset)
  ;;

  let recvfrom_assume_fd_is_nonblocking t fd =
    debug "recvfrom_assume_fd_is_nonblocking" [t] fd
      (<:sexp_of< File_descr.t >>)
      (<:sexp_of< int * Unix.sockaddr >>)
      (fun () -> recvfrom_assume_fd_is_nonblocking t fd)
  ;;

  let recvmmsg_assume_fd_is_nonblocking =
    Or_error.map recvmmsg_assume_fd_is_nonblocking ~f:(fun recvmmsg fd ?count ?srcs ts ->
      debug "recvmmsg_assume_fd_is_nonblocking" (Array.to_list ts)
        (fd, `count count, `srcs srcs)
        (<:sexp_of< (File_descr.t
                     * [ `count of int option ]
                     * [ `srcs of Unix.sockaddr array option ]) >>)
        (<:sexp_of< int >>)
        (fun () -> recvmmsg fd ?count ?srcs ts))
  ;;

  let send_nonblocking_no_sigpipe () =
    match send_nonblocking_no_sigpipe () with
    | Error _ as x -> x
    | Ok send_nonblocking_no_sigpipe ->
      Ok (fun t fd ->
        debug "send_nonblocking_no_sigpipe" [t] (fd, t)
          (<:sexp_of< File_descr.t * (_, _) t >>)
          (<:sexp_of< int option >>)
          (fun () -> send_nonblocking_no_sigpipe t fd))
  ;;

  let sendto_nonblocking_no_sigpipe () =
    Or_error.map (sendto_nonblocking_no_sigpipe ()) ~f:(fun f t fd addr ->
      debug "sendto_nonblocking_no_sigpipe" [t] (fd, addr)
        <:sexp_of< File_descr.t * Unix.sockaddr >>
        <:sexp_of< int option >>
        (fun () -> f t fd addr))

  let write_assume_fd_is_nonblocking t fd =
    debug "write_assume_fd_is_nonblocking" [t] (fd, t)
      (<:sexp_of< File_descr.t * (_, _) t >>)
      (<:sexp_of< int >>)
      (fun () -> write_assume_fd_is_nonblocking t fd)
  ;;

  let pwrite_assume_fd_is_nonblocking t fd ~offset =
    debug "pwrite_assume_fd_is_nonblocking" [t] (fd, t, `offset offset)
      (<:sexp_of< File_descr.t * (_, _) t * [ `offset of int ] >>)
      (<:sexp_of< int >>)
      (fun () -> pwrite_assume_fd_is_nonblocking t fd ~offset)
  ;;

  module Unsafe = struct
    open Unsafe

    (* Sorry, these are almost textual copies of the functions above.  For test purposes,
       it might be possible to functorize some of this. *)

    module Consume = struct
      let d name f sexp_of_result t =
        debug ("Unsafe.Consume." ^ name) [t] t <:sexp_of< (_, _) t >> sexp_of_result
          (fun () -> f t)
      ;;

      open Consume

      type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

      let char        t = d "char"        char        sexp_of_char  t
      let  int8       t = d  "int8"        int8       sexp_of_int   t
      let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
      let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
      let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
      let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
      let uint8       t = d "uint8"       uint8       sexp_of_int   t
      let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
      let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
      let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
      let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
      let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
      let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
      let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
      let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

      let padded_fixed_string ~padding ~len t =
        debug "Unsafe.Consume.padded_fixed_string" [t] (`padding padding, `len len)
          <:sexp_of< [ `padding of char ] * [ `len of int ] >>
          sexp_of_string
          (fun () -> padded_fixed_string ~padding ~len t)

      let string ?str_pos ?len t =
        debug "Unsafe.Consume.string" [t] (`str_pos str_pos, `len len)
          <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] >>
          sexp_of_string
          (fun () -> string ?str_pos ?len t)

      let bigstring ?str_pos ?len t =
        debug "Unsafe.Consume.bigstring" [t] (`str_pos str_pos, `len len)
          <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] >>
          sexp_of_bigstring
          (fun () -> bigstring ?str_pos ?len t)
    end
    module Fill = struct
      let d name f sexp_of_arg t arg =
        debug ("Unsafe.Fill." ^ name) [t] arg sexp_of_arg sexp_of_unit (fun () ->
          f t arg)
      ;;

      open Fill

      type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

      let char        t = d "char"        char        sexp_of_char  t
      let  int8       t = d  "int8"        int8       sexp_of_int   t
      let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
      let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
      let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
      let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
      let uint8       t = d "uint8"       uint8       sexp_of_int   t
      let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
      let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
      let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
      let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
      let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
      let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
      let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
      let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

      let padded_fixed_string ~padding ~len t str =
        debug "Unsafe.Fill.padded_fixed_string" [t] (`padding padding, `len len, str)
          <:sexp_of< [ `padding of char ] * [ `len of int ] * string >>
          sexp_of_unit
          (fun () -> padded_fixed_string ~padding ~len t str)

      let string ?str_pos ?len t str =
        debug "Unsafe.Fill.string" [t] (`str_pos str_pos, `len len, str)
          <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] * string >>
          sexp_of_unit
          (fun () -> string ?str_pos ?len t str)

      let bigstring ?str_pos ?len t str =
        debug "Unsafe.Fill.bigstring" [t] (`str_pos str_pos, `len len, str)
          <:sexp_of< [ `str_pos of int option ] * [ `len of int option ] * bigstring >>
          sexp_of_unit
          (fun () -> bigstring ?str_pos ?len t str)
    end
    module Peek = struct
      let d name f sexp_of_result t ~pos =
        debug ("Unsafe.Peek." ^ name)
          [t]
          (`pos pos)
          <:sexp_of< [ `pos of int ] >>
          sexp_of_result
          (fun () -> f t ~pos)
      ;;

      open Peek

      type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

      let char        t = d "char"        char        sexp_of_char  t
      let  int8       t = d  "int8"        int8       sexp_of_int   t
      let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
      let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
      let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
      let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
      let uint8       t = d "uint8"       uint8       sexp_of_int   t
      let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
      let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
      let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
      let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
      let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
      let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
      let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
      let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

      let padded_fixed_string ~padding ~len t ~pos =
        debug "Unsafe.Peek.padded_fixed_string" [t] (`padding padding, `len len, `pos pos)
          <:sexp_of< [ `padding of char ] * [ `len of int ] * [ `pos of int ] >>
          sexp_of_string
          (fun () -> padded_fixed_string ~padding ~len t ~pos)

      let string ?str_pos ?len t ~pos =
        debug "Unsafe.Peek.string" [t] (`str_pos str_pos, `len len, `pos pos)
          <:sexp_of< [ `str_pos of int option ]
                    * [ `len of int option ]
                    * [ `pos of int ] >>
          sexp_of_string
          (fun () -> string ?str_pos ?len t ~pos)

      let bigstring ?str_pos ?len t ~pos =
        debug "Unsafe.Peek.bigstring" [t] (`str_pos str_pos, `len len, `pos pos)
          <:sexp_of< [ `str_pos of int option ]
                    * [ `len of int option ]
                    * [ `pos of int ] >>
          sexp_of_bigstring
          (fun () -> bigstring ?str_pos ?len t ~pos)
    end
    module Poke = struct
      let d name f sexp_of_arg t ~pos arg =
        debug ("Unsafe.Poke." ^ name)
          [t]
          (`pos pos, arg)
          (Tuple.T2.sexp_of_t <:sexp_of< [ `pos of int ] >> sexp_of_arg)
          sexp_of_unit
          (fun () -> f t ~pos arg)
      ;;

      open Poke

      type nonrec ('a, 'd, 'w) t = ('a, 'd, 'w) t

      let char        t = d "char"        char        sexp_of_char  t
      let  int8       t = d  "int8"        int8       sexp_of_int   t
      let  int16_be   t = d  "int16_be"    int16_be   sexp_of_int   t
      let  int16_le   t = d  "int16_le"    int16_le   sexp_of_int   t
      let  int32_be   t = d  "int32_be"    int32_be   sexp_of_int   t
      let  int32_le   t = d  "int32_le"    int32_le   sexp_of_int   t
      let uint8       t = d "uint8"       uint8       sexp_of_int   t
      let uint16_be   t = d "uint16_be"   uint16_be   sexp_of_int   t
      let uint16_le   t = d "uint16_le"   uint16_le   sexp_of_int   t
      let uint32_be   t = d "uint32_be"   uint32_be   sexp_of_int   t
      let uint32_le   t = d "uint32_le"   uint32_le   sexp_of_int   t
      let  int64_be   t = d  "int64_be"    int64_be   sexp_of_int   t
      let  int64_le   t = d  "int64_le"    int64_le   sexp_of_int   t
      let  int64_t_be t = d  "int64_t_be"  int64_t_be sexp_of_int64 t
      let  int64_t_le t = d  "int64_t_le"  int64_t_le sexp_of_int64 t

      let padded_fixed_string ~padding ~len t ~pos str =
        debug "Unsafe.Poke.padded_fixed_string" [t]
          (`padding padding, `len len, `pos pos, str)
          <:sexp_of< [ `padding of char ]
                    * [ `len of int ]
                    * [ `pos of int ]
                    * string >>
          sexp_of_unit
          (fun () -> padded_fixed_string ~padding ~len t ~pos str)

      let string ?str_pos ?len t ~pos str =
        debug "Unsafe.Poke.string" [t] (`str_pos str_pos, `len len, `pos pos, str)
          <:sexp_of< [ `str_pos of int option ]
                    * [ `len of int option ]
                    * [ `pos of int ]
                    * string >>
          sexp_of_unit
          (fun () -> string ?str_pos ?len t ~pos str)

      let bigstring ?str_pos ?len t ~pos str =
        debug "Unsafe.Poke.bigstring" [t] (`str_pos str_pos, `len len, `pos pos, str)
          <:sexp_of< [ `str_pos of int option ]
                    * [ `len of int option ]
                    * [ `pos of int ]
                    * bigstring >>
          sexp_of_unit
          (fun () -> bigstring ?str_pos ?len t ~pos str)
    end
  end
end