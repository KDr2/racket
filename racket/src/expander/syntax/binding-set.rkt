#lang racket/base
(require "syntax.rkt"
         "scope.rkt"
         "module-binding.rkt"
         "../common/phase+space.rkt")

(provide syntax-binding-set
         syntax-binding-set?
         syntax-binding-set-extend
         syntax-binding-set->syntax)

(struct syntax-binding-set (binds))
(struct bind (sym phase binding))

(define (syntax-binding-set-extend bs as-sym as-phase mpi
                                   sym phase
                                   nominal-mpi nominal-phase+space nominal-sym
                                   nominal-require-phase+space-shift
                                   inspector)
  (struct-copy syntax-binding-set bs
               [binds
                (cons (bind as-sym
                            as-phase
                            (make-module-binding mpi phase sym
                                                 #:extra-inspector inspector
                                                 #:nominal-module nominal-mpi
                                                 #:nominal-phase+space nominal-phase+space
                                                 #:nominal-sym nominal-sym
                                                 #:nominal-require-phase+space-shift nominal-require-phase+space-shift))
                      (syntax-binding-set-binds bs))]))

(define (syntax-binding-set->syntax bs datum)
  (define s (add-scope (datum->syntax #f datum)
                       (new-multi-scope 'binding-set)))
  (for ([bind (in-list (syntax-binding-set-binds bs))])
    (add-binding-in-scopes! (syntax-scope-set s (bind-phase bind))
                            (bind-sym bind)
                            (bind-binding bind)))
  s)
