#lang racket/base
(require (rename-in syntax/private/boundmap
                    ;; the private version of the library 
                    ;; (the one without contracts)
                    ;; has these old, wrong names in it.
                    [make-module-identifier-mapping make-free-identifier-mapping]
                    [module-identifier-mapping-get free-identifier-mapping-get]
                    [module-identifier-mapping-put! free-identifier-mapping-put!]
                    [module-identifier-mapping-for-each free-identifier-mapping-for-each])
         "arr-util.rkt"
         (for-template racket/base
                       "misc.rkt"))

#|

The ->i contract first parses its input into an istx struct 
and then operates on it to generate the expanded form. This
code does the parsing and validation of the syntax.

|#

;; is-chaperone-contract? : boolean?
;; args : (listof arg?)
;; rst  : (or/c #f arg/res?)
;; pre  : (listof pre/post?)
;; params : (listof param?)
;; ress : (or/c #f (listof eres?) (listof lres?))
;; post : (listof pre/post?)
(struct istx (is-chaperone-contract? args rst pre params ress post) #:transparent)
;; NOTE: the ress field may contain a mixture of eres and lres structs
;;       but only temporarily; in that case, a syntax error
;;       is signaled and the istx struct is not used afterwards

;; var  : identifier?
;; vars : (or/c #f (listof identifier?))  -- #f if non-dep
;; ctc  : syntax[expr]
;; quoted-dep-src-code : sexp -- only useful if vars is not #f
(struct arg/res (var vars ctc quoted-dep-src-code) #:transparent)

;; kwd  : (or/c #f syntax[kwd])
;; optional? : boolean?
(struct arg arg/res (kwd optional?) #:transparent)

;; these represent res contracts that came from _s (and thus should be evaluated early)
;; eid : identifier?  --- extra variable to be bound to the result 
;;                    --- of evaluating the result contract early
(struct eres arg/res (eid) #:transparent)

;; these represent res contracts that do not come from _s (and thus should be evaluated later)
(struct lres arg/res () #:transparent)

;; vars : (listof identifier?)
;; exp  : syntax[expr]
;; kind : (or/c syntax[expr] 'desc 'bool)
;;         syntax => #:pre/name, where the syntax object holds the literal string
;;         'desc => #:pre/desc or #:post/desc
;;         'bool => #:pre or #:post
(struct pre/post (vars kind exp quoted-dep-src-code) #:transparent)
(struct pre/post-pre pre/post () #:transparent)
(struct pre/post-post pre/post () #:transparent)

;; vars : (listof identifier?)
;; pexp : syntax[expr]
;; vexp : syntax[expr]
;; quoted-pexp : sexpr
;; quoted-vexp : sexpr
(struct param (vars pexp vexp quoted-pexp quoted-vexp) #:transparent)

(define (parse-->i stx)
  (if (identifier? stx)
      (raise-syntax-error #f "expected ->i to follow an open parenthesis" stx)
      (let-values ([(is-chaperone-contract?
                     raw-mandatory-doms raw-optional-doms
                     id/rest-id pre-cond params range post-cond)
                    (pull-out-pieces stx)])
        (let ([candidate
               (istx is-chaperone-contract?
                     (append (parse-doms stx #f raw-mandatory-doms)
                             (parse-doms stx #t raw-optional-doms))
                     id/rest-id
                     pre-cond
                     params
                     (parse-range stx range)
                     post-cond)])
          (ensure-wf-names stx candidate)
          (ensure-no-cycles stx candidate)
          candidate))))

(define (ensure-wf-names stx istx)
  (let ([km (make-hash)]
        [nm (make-free-identifier-mapping)])
    
    (define (no-var-dups var)
      (cond
        [(free-identifier-mapping-get nm var (λ () #f))
         =>
         (λ (other)
           (raise-syntax-error #f "duplicate dependent variables"
                               stx other (list var)))]
        [else
         (free-identifier-mapping-put! nm var var)]))
    
    (define (no-kwd-dups kwd-stx)
      (let ([kwd (syntax-e kwd-stx)])
        (cond
          [(hash-ref km kwd #f)
           =>
           (λ (that)
             (raise-syntax-error #f "duplicate keywords" 
                                 stx that (list kwd-stx)))]
          [else
           (hash-set! km kwd kwd-stx)])))
    
    (define (ensure-bound vars)
      (for ([var (in-list vars)])
        (unless (free-identifier-mapping-get nm var (λ () #f))
          (define vars '())
          (free-identifier-mapping-for-each
           nm
           (λ (id _)
             (define sym (syntax-e id))
             (unless (member sym vars)
               (set! vars (cons sym vars)))))

          (define (insert x l)
            (cond
              [(null? l) (list x)]
              [else
               (cond
                 [(symbol<? x (car l))
                  (cons x l)]
                 [else
                  (cons (car l) (insert x (cdr l)))])]))

          (define sorted-vars
            (let loop ([vars vars])
              (cond
                [(null? vars) '()]
                [else (insert (car vars) (loop (cdr vars)))])))
          
          (raise-syntax-error
           #f
           (apply
            string-append
            "unknown dependent variable;"
            "\n not the variable used in any of the components of the ->i expression"
            "\n  variables:"
            (for/list ([var (in-list sorted-vars)]
                       [i (in-naturals)])
              (format " ~a" var)))
           stx var))))
    
    ;; not-range-bound : (listof identifier[used-by-an-arg]) -> void
    (define (not-range-bound arg-vars arg?)
      (when (istx-ress istx)
        (for ([arg-var (in-list arg-vars)])
          (when (ormap (λ (a-res) (free-identifier=? (arg/res-var a-res) arg-var))
                       (istx-ress istx))
            (raise-syntax-error #f
                                (if arg? 
                                    "an argument cannot depend on a result"
                                    "a #:pre or #:pre/name condition cannot depend on a result")
                                stx arg-var)))))
    
    ;; no dups in the domains
    (for ([dom (in-list (istx-args istx))])
      (when (arg-kwd dom)
        (no-kwd-dups (arg-kwd dom)))
      (no-var-dups (arg/res-var dom)))
    
    ;; no dups in the ranges
    (when (istx-ress istx)
      (let ([any-eres? #f]
            [all-eres? #t])
        (for ([res (in-list (istx-ress istx))])
          (cond
            [(eres? res)
             (set! any-eres? #t)]
            [else 
             (set! all-eres? #f)
             (no-var-dups (arg/res-var res))]))
        (when any-eres?
          (unless all-eres?
            (raise-syntax-error
             #f
             "either all or none of the dependent range variables must be _"
             stx #f (map arg/res-var (istx-ress istx)))))))
    
    ;; no dups in the rest var
    (when (istx-rst istx)
      (when (arg/res-vars (istx-rst istx))
        (ensure-bound (arg/res-vars (istx-rst istx)))
        (not-range-bound (arg/res-vars (istx-rst istx)) #t))
      (no-var-dups (arg/res-var (istx-rst istx))))
    
    ;; dependent arg variables are all bound, but not to a range variable
    (for ([an-arg (in-list (istx-args istx))])
      (let ([a-vars (arg/res-vars an-arg)])
        (when a-vars
          (ensure-bound a-vars)
          (not-range-bound a-vars #t))))
    
    ;; pre-condition variables are all bound, but not to a range variable
    (for ([pre (in-list (istx-pre istx))])
      (let ([vars (pre/post-vars pre)])
        (ensure-bound vars)
        (not-range-bound vars #f)))

    ;; dependent range variables are all bound.
    (when (istx-ress istx)
      (for ([a-res (in-list (istx-ress istx))])
        (when (arg/res-vars a-res)
          (ensure-bound (arg/res-vars a-res)))))
    
    ;; post-condition variables are all bound
    (for ([post (in-list (istx-post istx))])
      (let ([vars (pre/post-vars post)])
        (ensure-bound vars)))))

(define (ensure-no-cycles stx istx)
  (let ([neighbors (make-free-identifier-mapping)]
        [safe (make-free-identifier-mapping)]
        [sp '()])

    (define (link from to)
      (set! sp (cons from sp))
      (free-identifier-mapping-put!
       neighbors from
       (cons to (free-identifier-mapping-get neighbors from))))
    
    (define (init-neighbors var)
      (free-identifier-mapping-put! neighbors var '()))
    
    (define (no-links from)
      (set! sp (cons from sp))
      (free-identifier-mapping-put! neighbors from '()))
    
    (define (handle-arg/ress arg/ress)
      (for ([a-res (in-list arg/ress)])
        (cond
          [(arg/res-vars a-res)
           (init-neighbors (arg/res-var a-res))
           (for ([nvar (in-list (arg/res-vars a-res))])
             (link (arg/res-var a-res) nvar))]
          [else
           (no-links (arg/res-var a-res))])))
    
    (handle-arg/ress (istx-args istx))
    
    (when (istx-ress istx)
      (handle-arg/ress (istx-ress istx)))
    
    (let ([a-rst (istx-rst istx)])
      (when a-rst
        (cond
          [(arg/res-vars a-rst)
           (init-neighbors (arg/res-var a-rst))
           (for ([nvar (in-list (arg/res-vars a-rst))])
             (link (arg/res-var a-rst) nvar))]
          [else
           (no-links (arg/res-var a-rst))])))
           
    (for ([var (in-list sp)])
      (let loop ([var var]
                 [visited '()])
        (cond
          [(free-identifier-mapping-get safe var (λ () #f))
           (void)]
          [(memf (λ (x) (free-identifier=? x var)) visited)
           (define ids (trim-at var visited))
           (cond
             [(null? (cdr ids))
              (raise-syntax-error #f 
                                  (format "~s's contract depends on ~s's value"
                                          (syntax-e (car ids))
                                          (syntax-e (car ids)))
                                  stx
                                  (car ids))]
             [else
              (raise-syntax-error 
               #f 
               (format "generation of ~s's contract depends on ~s's value; specifically:~a~a"
                       (syntax-e (car ids))
                       (syntax-e (car ids))
                       (apply
                        string-append
                        (for/list ([i (in-list ids)]
                                   [j (in-list (cdr ids))])
                          (format "\n  ~s's contract depends on ~s"
                                  (syntax-e i)
                                  (syntax-e j))))
                       (format " and\n  ~s's contract depends on ~a"
                               (syntax-e (car (reverse ids)))
                               (syntax-e (car ids))))
               stx
               (car ids)
               (cdr ids))])]
          [else
           (let ([new-visited (cons var visited)])
             (for ([neighbor (in-list (free-identifier-mapping-get neighbors var))])
               (loop neighbor new-visited))
             (free-identifier-mapping-put! safe var #t))])))))

;; trim-at : identifier? (listof identifier?) -> (listof identifier?)
;; returns the shortest prefix of vars that ends with var
(define (trim-at var vars)
  (let loop ([vars vars])
    (cond
      [(null? vars) (error 'trim-at "not found")]
      [else (let ([fst (car vars)])
              (if (free-identifier=? fst var)
                  (list fst)
                  (cons fst (loop (cdr vars)))))])))

(define (parse-doms stx optional? doms)
  (let loop ([doms doms])
    (syntax-case doms ()
      [(kwd [id ctc-expr] . rest)
       (keyword? (syntax-e #'kwd))
       (begin
         (check-id stx #'id)
         (cons (arg #'id #f #'ctc-expr #f #'kwd optional?)
               (loop #'rest)))]
      [(kwd [id (id2 ...) ctc-expr] . rest)
       (keyword? (syntax-e #'kwd))
       (begin
         (check-id stx #'id)
         (for-each (λ (x) (check-id stx x)) (syntax->list #'(id2 ...)))
         (cons (arg #'id (syntax->list #'(id2 ...)) #'ctc-expr
                    (compute-quoted-src-expression #'ctc-expr)
                    #'kwd optional?)
               (loop #'rest)))]
      [([id ctc-expr] . rest)
       (begin
         (check-id stx #'id)
         (cons (arg #'id #f #'ctc-expr #f #f optional?)
               (loop #'rest)))]
      [([id (id2 ...) ctc-expr] . rest)
       (begin
         (check-id stx #'id)
         (for-each (λ (x) (check-id stx x)) (syntax->list #'(id2 ...)))
         (cons (arg #'id (syntax->list #'(id2 ...)) #'ctc-expr
                    (compute-quoted-src-expression #'ctc-expr)
                    #f optional?)
               (loop #'rest)))]
      [() '()]
      [(a . rest)
       (raise-syntax-error #f "expected an argument specification" stx #'a)])))
  
(define (parse-range stx range)
  (syntax-case range (any values _)
    [(values ctc-pr ...)
     (map (λ (x) (syntax-case x (_)
                   [[id ctc] 
                    (begin
                      (check-id stx #'id)
                      (if (free-identifier=? #'_ #'id) 
                          (eres #'id #f #'ctc (car (generate-temporaries '(eres))) #f)
                          (lres #'id #f #'ctc #f)))]
                   [[id (id2 ...) ctc]
                    (begin
                      (check-id stx #'id)
                      (for-each (λ (x) (check-id stx x)) (syntax->list #'(id2 ...)))
                      (if (free-identifier=? #'_ #'id) 
                          (eres #'id (syntax->list #'(id2 ...)) #'ctc
                                (compute-quoted-src-expression #'ctc)
                                (car (generate-temporaries '(eres))))
                          (lres #'id (syntax->list #'(id2 ...)) #'ctc
                                (compute-quoted-src-expression #'ctc))))]
                   [(a ...)
                    (let ([len (length (syntax->list #'(a ...)))])
                      (unless (or (= 2 len) (= 3 len))
                        (raise-syntax-error
                         #f
                         "wrong number of pieces in range portion of the contract, expected id+ctc"
                         stx #'x))
                      (raise-syntax-error #f "expected id+ctc in range portion of contract" stx #'x))]
                   [x 
                    (raise-syntax-error #f "expected id+ctc in range portion of contract" stx #'x)]))
          (syntax->list #'(ctc-pr ...)))]
    [any #f]
    [[_ ctc]
     (list (eres #'_ #f #'ctc #f (car (generate-temporaries '(eres)))))]
    [[id ctc]
     (begin
       (check-id stx #'id)
       (list (lres #'id #f #'ctc #f)))]
    [[_ (id2 ...) ctc] 
     (begin
       (for-each (λ (x) (check-id stx x)) (syntax->list #'(id2 ...)))
       (list (eres (car (syntax-e range))
                   (syntax->list #'(id2 ...)) #'ctc
                   (compute-quoted-src-expression #'ctc)
                   (car (generate-temporaries '(eres))))))]
    [[id (id2 ...) ctc] 
     (begin
       (check-id stx #'id)
       (for-each (λ (x) (check-id stx x)) (syntax->list #'(id2 ...)))
       (list (lres #'id (syntax->list #'(id2 ...)) #'ctc
                   (compute-quoted-src-expression #'ctc))))]
    [x (raise-syntax-error #f "expected the range portion" stx #'x)]))

(define (check-id stx id)
  (unless (identifier? id)
    (raise-syntax-error #f "expected an identifier" stx id)))

;; pull-out-pieces :
;; stx -> (values raw-mandatory-doms raw-optional-doms id/rest-id pre-cond range post-cond) 
(define (pull-out-pieces stx)
  (let*-values ([(is-chaperone-contract? leftover)
                 (syntax-case stx ()
                   [(_ #:chaperone . leftover)
                    (values #t #'leftover)]
                   [(_ . leftover)
                    (let ([lst (syntax->list stx)])
                      (when (null? (cdr lst))
                        (raise-syntax-error #f "expected a sequence of mandatory domain elements"
                                            stx))
                      (when (keyword? (syntax-e (cadr lst)))
                        (raise-syntax-error #f "unknown keyword"
                                            stx
                                            (cadr lst)))
                      (values #f #'leftover))])]
                [(raw-mandatory-doms leftover)
                 (syntax-case leftover ()
                   [((raw-mandatory-doms ...) . leftover)
                    (values (syntax->list #'(raw-mandatory-doms ...)) 
                            #'leftover)]
                   [(a . leftover)
                    (raise-syntax-error #f 
                                        "expected a sequence of mandatory domain elements"
                                        stx #'a)]
                   [_
                    (raise-syntax-error #f "expected a sequence of mandatory domain elements" stx)])]
                [(raw-optional-doms leftover)
                 (syntax-case leftover ()
                   [(kwd . leftover2)
                    (keyword? (syntax-e #'kwd))
                    (values '() leftover)]
                   [(dep-range)
                    (values '() leftover)]
                   [(dep-range #:post . stuff)
                    (values '() leftover)]
                   [(dep-range #:post/desc . stuff)
                    (values '() leftover)]
                   [(dep-range #:post/name . stuff)
                    (values '() leftover)]
                   [((opts ...) . rest)
                    (values #'(opts ...) #'rest)]
                   [_ (values '() leftover)])]
                [(id/rest-id leftover) 
                 (syntax-case leftover ()
                   [(#:rest [id rest-expr] . leftover)
                    (begin
                      (check-id stx #'id)
                      (values (arg/res #'id #f #'rest-expr #f)
                              #'leftover))]
                   [(#:rest [id (id2 ...) rest-expr] . leftover)
                    (begin
                      (check-id stx #'id)
                      (for-each (λ (x) (check-id stx x))
                                (syntax->list #'(id2 ...)))
                      (values (arg/res #'id 
                                       (syntax->list #'(id2 ...))
                                       #'rest-expr
                                       (compute-quoted-src-expression #'rest-expr))
                              #'leftover))]
                   [(#:rest other . leftover)
                    (raise-syntax-error #f "expected an id+ctc"
                                        stx
                                        #'other)]
                   [(x)
                    (eq? (syntax-e #'x) '#:rest)
                    (raise-syntax-error 
                     #f 
                     "expected something to follow #:rest"
                     stx #'x)]
                   [_ (values #f leftover)])]
                [(pre-conds leftover)
                 (let loop ([leftover leftover]
                            [conditions '()])
                   (syntax-case leftover ()
                     [(kwd (id ...) pre-cond . pre-leftover)
                      (or (equal? (syntax-e #'kwd) '#:pre)
                          (equal? (syntax-e #'kwd) '#:pre/desc))
                      (begin
                        (syntax-case #'pre-leftover ()
                          [() (raise-syntax-error 
                               #f
                               (format
                                (string-append
                                 "expected ~a to be followed by at least three subterms"
                                 " (a sequence of identifiers, the pre-condition, and the"
                                 " range contract), but found only two")
                                (syntax-e #'kwd))
                               stx
                               (car (syntax->list leftover)))]
                          [x (void)])
                        (for-each (λ (x) (check-id stx x)) (syntax->list #'(id ...)))
                        (loop #'pre-leftover 
                              (cons (pre/post-pre (syntax->list #'(id ...))
                                                  (if (equal? '#:pre/desc (syntax-e #'kwd))
                                                      'desc
                                                      'bool)
                                                  #'pre-cond
                                                  (compute-quoted-src-expression #'pre-cond))
                                    conditions)))]
                     [(kwd . rest)
                      (or (equal? (syntax-e #'kwd) '#:pre)
                          (equal? (syntax-e #'kwd) '#:pre/desc))
                      (raise-syntax-error
                       #f
                       (format "expected a sequence of identifiers and an expression to follow ~a"
                               (syntax-e #'kwd))
                       stx
                       (car (syntax->list leftover)))]
                     [(#:pre/name (id ...) str pre-cond . pre-leftover)
                      (begin
                        (syntax-case #'pre-leftover ()
                          [() (raise-syntax-error 
                               #f
                               (string-append
                                "expected #:pre/name to be followed by at least four subterms"
                                " (a sequence of identifiers, a name, the pre-condition, and the"
                                " range contract), but found only three")
                               stx
                               (car (syntax->list leftover)))]
                          [x (void)])
                        (for-each (λ (x) (check-id stx x)) (syntax->list #'(id ...)))
                        (unless (string? (syntax-e #'str))
                          (raise-syntax-error 
                           #f
                           "expected #:pre/name to have a string after the sequence of variables"
                           stx
                           #'str))
                        (loop #'pre-leftover
                              (cons (pre/post-pre (syntax->list #'(id ...))
                                                  (syntax-e #'str)
                                                  #'pre-cond
                                                  (compute-quoted-src-expression #'pre-cond))
                                    conditions)))]
                     [(#:pre/name . rest)
                      (raise-syntax-error
                       #f
                       (string-append
                        "expected a sequence of identifiers, a string,"
                        " and an expression to follow #:pre/name")
                       stx
                       (car (syntax->list leftover)))]
                     [_ (values (reverse conditions) leftover)]))]
                [(params leftover)
                 (let loop ([leftover leftover]
                            [params '()])
                   (syntax-case leftover ()
                     [(kwd (id ...) pexp vexp . param-leftover)
                      (equal? (syntax-e #'kwd) '#:param)
                      (begin
                        (syntax-case #'param-leftover ()
                          [() (raise-syntax-error
                               #f
                               (format
                                (string-append
                                 "expected ~a to be followed by at least four subterms"
                                 " (a sequence of identifiers, the parameter, the parameter value"
                                 " and the range contract), but found only three")
                                (syntax-e #'kwd))
                               stx
                               (car (syntax->list leftover)))]
                          [x (void)])
                        (for-each (λ (x) (check-id stx x)) (syntax->list #'(id ...)))
                        (loop #'param-leftover
                              (cons (param (syntax->list #'(id ...))
                                           #'pexp #'vexp
                                           (compute-quoted-src-expression #'pexp)
                                           (compute-quoted-src-expression #'vexp))
                                    params)))]
                     [(kwd . rest)
                      (equal? (syntax-e #'kwd) '#:param)
                      (raise-syntax-error
                       #f
                       (format "expected a sequence of identifiers and two expressions to follow ~a"
                               (syntax-e #'kwd))
                       stx
                       (car (syntax->list leftover)))]
                     [_ (values (reverse params) leftover)]))]
                [(range leftover) 
                 (begin
                   (syntax-case leftover ()
                     [(range . leftover) 
                      (not (keyword? (syntax-e #'range)))
                      (values #'range #'leftover)]
                     [(a . b)
                      (raise-syntax-error #f "expected a range expression" stx #'a)]
                     [()
                      (raise-syntax-error #f "expected a range expression, but found nothing" stx)]))]
                [(post-conds leftover) 
                 (let loop ([leftover leftover]
                            [post-conds '()])
                   (syntax-case leftover ()
                     [(kwd (id ...) post-cond . leftover)
                      (or (equal? (syntax-e #'kwd) '#:post/desc)
                          (equal? (syntax-e #'kwd) '#:post))
                      (begin
                        (for-each (λ (x) (check-id stx x)) (syntax->list #'(id ...)))
                        (syntax-case range (any)
                          [any (raise-syntax-error
                                #f
                                (format "cannot have a ~a with any as the range"
                                        (syntax-e #'kwd))
                                stx #'post-cond)]
                          [_ (void)])
                        (loop #'leftover
                              (cons (pre/post-post (syntax->list #'(id ...))
                                                   (if (equal? (syntax-e #'kwd) '#:post/desc)
                                                       'desc
                                                       'bool)
                                                   #'post-cond
                                                   (compute-quoted-src-expression #'post-cond))
                                    post-conds)))]
                     [(kwd a b . stuff)
                      (or (equal? (syntax-e #'kwd) '#:post/desc)
                          (equal? (syntax-e #'kwd) '#:post))
                      (begin
                        (raise-syntax-error
                         #f
                         (format "expected a sequence of variables to follow ~a"
                                 (syntax-e #'kwd))
                         stx #'a))]
                     [(kwd a)
                      (or (equal? (syntax-e #'kwd) '#:post/desc)
                          (equal? (syntax-e #'kwd) '#:post))
                      (begin
                        (raise-syntax-error 
                         #f 
                         (format "expected a sequence of variables and an expression to follow ~a"
                                 (syntax-e #'kwd))
                         stx #'a))]
                     [(#:post/name (id ...) str post-cond . post-leftover)
                      (begin
                        (for-each (λ (x) (check-id stx x)) (syntax->list #'(id ...)))
                        (syntax-case range (any)
                          [any (raise-syntax-error 
                                #f "cannot have a #:post with any as the range" stx #'post-cond)]
                          [_ (void)])
                        (unless (string? (syntax-e #'str))
                          (raise-syntax-error 
                           #f
                           (string-append 
                            "expected the error message part of a #:post/name"
                            " declaration to be a string")
                           stx
                           #'str))
                        (loop #'post-leftover
                              (cons (pre/post-post (syntax->list #'(id ...)) (syntax-e #'str)
                                                   #'post-cond
                                                   (compute-quoted-src-expression #'post-cond))
                                    post-conds)))]
                     [(#:post/name . stuff)
                      (begin
                        (raise-syntax-error 
                         #f
                         (string-append "expected a sequence of variables, a string,"
                                        " and an expression to follow #:post/name")
                         stx
                         (car (syntax-e leftover))))]
                     
                     [_
                      (values (reverse post-conds) leftover)]))])
    (syntax-case leftover ()
      [() 
       (values is-chaperone-contract?
               raw-mandatory-doms raw-optional-doms id/rest-id pre-conds params
               range post-conds)]
      [(a . b)
       (raise-syntax-error #f "bad syntax" stx #'a)]
      [_
       (raise-syntax-error #f "bad syntax" stx)])))

(provide
 parse-->i
 (struct-out istx)
 (struct-out arg/res)
 (struct-out arg)
 (struct-out lres)
 (struct-out eres)
 (struct-out pre/post)
 (struct-out pre/post-pre)
 (struct-out pre/post-post)
 (struct-out param))
