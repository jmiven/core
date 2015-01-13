(** Representation of Unix system call results

    Almost no Unix system call returns a negative integer in case of success.

    We can use this to encode the result of a system call as either a positive integer
    value or [-errno].  This allows us to avoid exceptions for dealing with errors such as
    [EAGAIN].  Indeed, in some context we issue a system call in a tight loop that will
    often fail with [EAGAIN] and using exceptions to return it is costly. *)

open Core_kernel.Std

(** There is no [with sexp_of] on purpose as it could only print the ['a] value as an
    integer.  Use [<:sexp_of< Int.t >>] or [<:sexp_of< Unit.t >>]. *)
type 'a t
  = private int (* performance hack *)

module type S   = Syscall_result_intf.S with type 'a syscall_result := 'a t
module type Arg = Syscall_result_intf.Arg

module Make (M : Arg) () : S with type ok_value := M.t

module Int  : S with type ok_value := int
module Unit : S with type ok_value := unit

val create_error : Unix_error.t -> _ t

val unit : Unit.t

(** Keep only the error. *)
val ignore_ok_value : _ t -> Unit.t
