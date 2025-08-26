;; ------------------------------------------------------------
;; BiometricSecurity Protocol (Clarity)
;; Decentralized biometric authentication using hash patterns
;; ------------------------------------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Error codes
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-constant err-owner-only            (err u100))
(define-constant err-unauthorized          (err u101))
(define-constant err-invalid-hash          (err u102))
(define-constant err-user-not-registered   (err u103))
(define-constant err-user-already-registered (err u104))
(define-constant err-verification-failed   (err u105))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Data structures
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Store per-user registration state and metadata.
(define-map user-registry
  principal
  {
    registered: bool,
    hash-pattern: (buff 32),
    verification-count: uint,
    last-verified: uint
  }
)

;; Track the latest authentication session per user.
(define-map authentication-sessions
  principal
  {
    session-id: uint,
    timestamp: uint,
    verified: bool,
    expires-at: uint
  }
)

;; Global counters
(define-data-var total-registered-users uint u0)
(define-data-var session-counter         uint u0)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Strict validation: require a full 32-byte hash (e.g., SHA-256)
(define-read-only (is-valid-hash (h (buff 32)))
  (is-eq (len h) u32)
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Registers a user's biometric pattern hash.
(define-public (register-biometric-pattern (biometric-hash (buff 32)))
  (let (
        (current-user tx-sender)
        (existing-user (map-get? user-registry current-user))
       )
    (begin
      ;; Ensure user is not already registered
      (asserts! (is-none existing-user) err-user-already-registered)

      ;; Validate hash buffer is exactly 32 bytes
      (asserts! (is-valid-hash biometric-hash) err-invalid-hash)

      ;; Register user
      (map-set user-registry current-user {
        registered: true,
        hash-pattern: biometric-hash,
        verification-count: u0,
        last-verified: u0
      })

      ;; Increment total registered users
      (var-set total-registered-users (+ (var-get total-registered-users) u1))

      ;; Emit event
      (print {
        event: "biometric-registered",
        user: current-user,
        timestamp: stacks-block-height
      })

      (ok true)
    )
  )
)

;; Verifies a user's identity by comparing the provided hash
;; with the registered pattern and creates a time-limited session.
(define-public (verify-biometric-authentication (biometric-hash (buff 32)))
  (let (
        (current-user tx-sender)
        (user-data (map-get? user-registry current-user))
        (new-session-id (+ (var-get session-counter) u1))
        (session-expiry (+ stacks-block-height u144)) ;; ~24h at 10-min blocks
       )
    (begin
      ;; Must be registered
      (asserts! (is-some user-data) err-user-not-registered)

      (match user-data user-info
        (begin
          ;; Strict hash length check first (clearer error)
          (asserts! (is-valid-hash biometric-hash) err-invalid-hash)

          ;; Compare provided hash to stored pattern
          (asserts!
            (is-eq biometric-hash (get hash-pattern user-info))
            err-verification-failed
          )

          ;; Update user stats
          (map-set user-registry current-user {
            registered: true,
            hash-pattern: (get hash-pattern user-info),
            verification-count: (+ (get verification-count user-info) u1),
            last-verified: stacks-block-height
          })

          ;; Store/overwrite latest session for this user
          (map-set authentication-sessions current-user {
            session-id: new-session-id,
            timestamp: stacks-block-height,
            verified: true,
            expires-at: session-expiry
          })

          ;; Bump global session counter
          (var-set session-counter new-session-id)

          ;; Emit event
          (print {
            event: "biometric-verified",
            user: current-user,
            session-id: new-session-id,
            timestamp: stacks-block-height
          })

          (ok {
            authenticated: true,
            session-id: new-session-id,
            expires-at: session-expiry
          })
        )
        ;; This branch is unreachable due to the asserts! above,
        ;; but included for completeness.
        err-user-not-registered
      )
    )
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only queries
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Check if a user is registered.
(define-read-only (is-user-registered (user principal))
  (match (map-get? user-registry user)
    user-data (get registered user-data)
    false
  )
)

;; Fetch user stats (no biometric data exposed).
(define-read-only (get-user-stats (user principal))
  (match (map-get? user-registry user)
    user-data
      (ok {
        registered: (get registered user-data),
        verification-count: (get verification-count user-data),
        last-verified: (get last-verified user-data)
      })
    (ok {
      registered: false,
      verification-count: u0,
      last-verified: u0
    })
  )
)

;; Get current (unexpired) authentication session for a user.
(define-read-only (get-authentication-session (user principal))
  (match (map-get? authentication-sessions user)
    session-data
      (if (> (get expires-at session-data) stacks-block-height)
          (ok (some session-data))
          (ok none)) ;; expired
    (ok none)
  )
)

;; Total number of registered users.
(define-read-only (get-total-registered-users)
  (var-get total-registered-users)
)
