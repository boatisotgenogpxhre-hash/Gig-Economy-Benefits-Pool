;; title: claim-verification-system
;; version: 1.0.0
;; summary: Medical and unemployment claim verification with instant benefit payouts
;; description: Smart contract for processing and verifying benefit claims for gig workers

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-INVALID-CLAIM (err u301))
(define-constant ERR-INSUFFICIENT-BALANCE (err u302))
(define-constant ERR-CLAIM-EXISTS (err u303))
(define-constant ERR-NOT-FOUND (err u304))
(define-constant ERR-INVALID-AMOUNT (err u305))
(define-constant ERR-CLAIM-EXPIRED (err u306))
(define-constant ERR-VERIFICATION-FAILED (err u307))
(define-constant ERR-PAYOUT-FAILED (err u308))

;; Contract owner and authorized verifiers
(define-constant CONTRACT-OWNER tx-sender)

;; Claim type constants
(define-constant CLAIM-TYPE-MEDICAL u1)
(define-constant CLAIM-TYPE-UNEMPLOYMENT u2)
(define-constant CLAIM-TYPE-DISABILITY u3)
(define-constant CLAIM-TYPE-EMERGENCY u4)

;; Claim status constants
(define-constant STATUS-PENDING u0)
(define-constant STATUS-VERIFIED u1)
(define-constant STATUS-REJECTED u2)
(define-constant STATUS-PAID u3)
(define-constant STATUS-EXPIRED u4)

;; Maximum claim amounts per type
(define-constant MAX-MEDICAL-CLAIM u500000000)    ;; 5000 STX
(define-constant MAX-UNEMPLOYMENT-CLAIM u300000000) ;; 3000 STX
(define-constant MAX-DISABILITY-CLAIM u800000000)   ;; 8000 STX
(define-constant MAX-EMERGENCY-CLAIM u200000000)    ;; 2000 STX

;; Claim verification timeouts (in blocks)
(define-constant VERIFICATION-TIMEOUT u1440) ;; ~24 hours assuming 1 minute blocks
(define-constant APPEAL-PERIOD u4320)        ;; ~72 hours for appeals

;; Claim records
(define-map benefit-claims
    { claim-id: uint }
    {
        claimant: principal,
        claim-type: uint,
        claim-amount: uint,
        claim-description: (string-ascii 500),
        supporting-documents: (list 5 (string-ascii 200)),
        submission-block: uint,
        verification-deadline: uint,
        status: uint,
        verified-by: (optional principal),
        verification-block: (optional uint),
        payout-block: (optional uint),
        rejection-reason: (optional (string-ascii 200))
    }
)

;; Claimant profiles
(define-map claimant-profiles
    { claimant: principal }
    {
        total-claims-submitted: uint,
        total-claims-approved: uint,
        total-amount-received: uint,
        last-claim-block: uint,
        is-eligible: bool,
        fraud-score: uint,
        contribution-months: uint
    }
)

;; Authorized verifiers
(define-map authorized-verifiers
    { verifier: principal }
    {
        is-active: bool,
        verification-count: uint,
        approval-rate: uint,
        specialization: uint,
        authorization-block: uint
    }
)

;; Claim verification evidence
(define-map verification-evidence
    { claim-id: uint }
    {
        medical-records-hash: (optional (buff 32)),
        employment-verification: (optional (string-ascii 200)),
        financial-statements: (optional (buff 32)),
        witness-statements: (list 3 (string-ascii 300)),
        verification-score: uint,
        risk-assessment: uint
    }
)

;; Payout records
(define-map claim-payouts
    { claim-id: uint }
    {
        payout-amount: uint,
        payout-recipient: principal,
        payout-block: uint,
        transaction-hash: (optional (buff 32)),
        payout-method: (string-ascii 50)
    }
)

;; Fraud detection patterns
(define-map fraud-patterns
    { pattern-id: uint }
    {
        pattern-description: (string-ascii 200),
        risk-score: uint,
        detection-count: uint,
        is-active: bool
    }
)

;; Global system variables
(define-data-var next-claim-id uint u1)
(define-data-var total-claims-submitted uint u0)
(define-data-var total-claims-approved uint u0)
(define-data-var total-amount-paid uint u0)
(define-data-var system-reserve-balance uint u1000000000000) ;; 10M STX initial reserve
(define-data-var verification-fee uint u1000000) ;; 10 STX verification fee
(define-data-var fraud-threshold uint u70) ;; 70% fraud threshold

;; Helper functions
(define-private (max (a uint) (b uint))
    (if (> a b) a b)
)

(define-private (min (a uint) (b uint))
    (if (< a b) a b)
)

;; Submit a new benefit claim
(define-public (submit-claim (claim-type uint) 
                           (claim-amount uint) 
                           (claim-description (string-ascii 500)) 
                           (supporting-documents (list 5 (string-ascii 200))))
    (let
        (
            (claim-id (var-get next-claim-id))
            (claimant-profile (default-to
                {
                    total-claims-submitted: u0,
                    total-claims-approved: u0,
                    total-amount-received: u0,
                    last-claim-block: u0,
                    is-eligible: true,
                    fraud-score: u0,
                    contribution-months: u0
                }
                (map-get? claimant-profiles {claimant: tx-sender})
            ))
            (max-amount (get-max-claim-amount claim-type))
        )
        
        (asserts! (get is-eligible claimant-profile) ERR-NOT-AUTHORIZED)
        (asserts! (is-valid-claim-type claim-type) ERR-INVALID-CLAIM)
        (asserts! (and (> claim-amount u0) (<= claim-amount max-amount)) ERR-INVALID-AMOUNT)
        (asserts! (< (get fraud-score claimant-profile) (var-get fraud-threshold)) ERR-VERIFICATION-FAILED)
        
        ;; Create the claim record
        (map-set benefit-claims
            {claim-id: claim-id}
            {
                claimant: tx-sender,
                claim-type: claim-type,
                claim-amount: claim-amount,
                claim-description: claim-description,
                supporting-documents: supporting-documents,
                submission-block: stacks-block-height,
                verification-deadline: (+ stacks-block-height VERIFICATION-TIMEOUT),
                status: STATUS-PENDING,
                verified-by: none,
                verification-block: none,
                payout-block: none,
                rejection-reason: none
            }
        )
        
        ;; Update claimant profile
        (map-set claimant-profiles
            {claimant: tx-sender}
            {
                total-claims-submitted: (+ (get total-claims-submitted claimant-profile) u1),
                total-claims-approved: (get total-claims-approved claimant-profile),
                total-amount-received: (get total-amount-received claimant-profile),
                last-claim-block: stacks-block-height,
                is-eligible: true,
                fraud-score: (get fraud-score claimant-profile),
                contribution-months: (get contribution-months claimant-profile)
            }
        )
        
        ;; Update global counters
        (var-set next-claim-id (+ claim-id u1))
        (var-set total-claims-submitted (+ (var-get total-claims-submitted) u1))
        
        (ok claim-id)
    )
)

;; Verify a claim (authorized verifiers only)
(define-public (verify-claim (claim-id uint) 
                           (approve bool) 
                           (rejection-reason (optional (string-ascii 200)))
                           (verification-score uint))
    (let
        (
            (claim-data (unwrap! (map-get? benefit-claims {claim-id: claim-id}) ERR-NOT-FOUND))
            (verifier-info (unwrap! (map-get? authorized-verifiers {verifier: tx-sender}) ERR-NOT-AUTHORIZED))
        )
        
        (asserts! (get is-active verifier-info) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status claim-data) STATUS-PENDING) ERR-INVALID-CLAIM)
        (asserts! (<= stacks-block-height (get verification-deadline claim-data)) ERR-CLAIM-EXPIRED)
        (asserts! (<= verification-score u100) ERR-INVALID-AMOUNT)
        
        (let
            (
                (new-status (if approve STATUS-VERIFIED STATUS-REJECTED))
                (claimant (get claimant claim-data))
                (claimant-profile (unwrap! (map-get? claimant-profiles {claimant: claimant}) ERR-NOT-FOUND))
            )
            
            ;; Update claim status
            (map-set benefit-claims
                {claim-id: claim-id}
                {
                    claimant: (get claimant claim-data),
                    claim-type: (get claim-type claim-data),
                    claim-amount: (get claim-amount claim-data),
                    claim-description: (get claim-description claim-data),
                    supporting-documents: (get supporting-documents claim-data),
                    submission-block: (get submission-block claim-data),
                    verification-deadline: (get verification-deadline claim-data),
                    status: new-status,
                    verified-by: (some tx-sender),
                    verification-block: (some stacks-block-height),
                    payout-block: none,
                    rejection-reason: rejection-reason
                }
            )
            
            ;; Update verifier statistics
            (map-set authorized-verifiers
                {verifier: tx-sender}
                {
                    is-active: true,
                    verification-count: (+ (get verification-count verifier-info) u1),
                    approval-rate: (calculate-approval-rate tx-sender approve),
                    specialization: (get specialization verifier-info),
                    authorization-block: (get authorization-block verifier-info)
                }
            )
            
            ;; If approved, initiate payout
            (if approve
                (begin
                    (try! (process-payout claim-id))
                    (map-set claimant-profiles
                        {claimant: claimant}
                        {
                            total-claims-submitted: (get total-claims-submitted claimant-profile),
                            total-claims-approved: (+ (get total-claims-approved claimant-profile) u1),
                            total-amount-received: (+ (get total-amount-received claimant-profile) (get claim-amount claim-data)),
                            last-claim-block: (get last-claim-block claimant-profile),
                            is-eligible: true,
                            fraud-score: (max (- (get fraud-score claimant-profile) u5) u0),
                            contribution-months: (get contribution-months claimant-profile)
                        }
                    )
                )
                ;; If rejected, increase fraud score
                (map-set claimant-profiles
                    {claimant: claimant}
                    {
                        total-claims-submitted: (get total-claims-submitted claimant-profile),
                        total-claims-approved: (get total-claims-approved claimant-profile),
                        total-amount-received: (get total-amount-received claimant-profile),
                        last-claim-block: (get last-claim-block claimant-profile),
                        is-eligible: true,
                        fraud-score: (min (+ (get fraud-score claimant-profile) u10) u100),
                        contribution-months: (get contribution-months claimant-profile)
                    }
                )
            )
            
            (ok new-status)
        )
    )
)

;; Process payout for approved claims
(define-private (process-payout (claim-id uint))
    (let
        (
            (claim-data (unwrap! (map-get? benefit-claims {claim-id: claim-id}) ERR-NOT-FOUND))
            (payout-amount (get claim-amount claim-data))
            (recipient (get claimant claim-data))
        )
        
        (asserts! (is-eq (get status claim-data) STATUS-VERIFIED) ERR-INVALID-CLAIM)
        (asserts! (>= (var-get system-reserve-balance) payout-amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Record the payout
        (map-set claim-payouts
            {claim-id: claim-id}
            {
                payout-amount: payout-amount,
                payout-recipient: recipient,
                payout-block: stacks-block-height,
                transaction-hash: none,
                payout-method: "stx-transfer"
            }
        )
        
        ;; Update claim status to paid
        (map-set benefit-claims
            {claim-id: claim-id}
            {
                claimant: (get claimant claim-data),
                claim-type: (get claim-type claim-data),
                claim-amount: (get claim-amount claim-data),
                claim-description: (get claim-description claim-data),
                supporting-documents: (get supporting-documents claim-data),
                submission-block: (get submission-block claim-data),
                verification-deadline: (get verification-deadline claim-data),
                status: STATUS-PAID,
                verified-by: (get verified-by claim-data),
                verification-block: (get verification-block claim-data),
                payout-block: (some stacks-block-height),
                rejection-reason: (get rejection-reason claim-data)
            }
        )
        
        ;; Update system balances
        (var-set system-reserve-balance (- (var-get system-reserve-balance) payout-amount))
        (var-set total-amount-paid (+ (var-get total-amount-paid) payout-amount))
        (var-set total-claims-approved (+ (var-get total-claims-approved) u1))
        
        (ok true)
    )
)

;; Get claim details
(define-read-only (get-claim (claim-id uint))
    (match (map-get? benefit-claims {claim-id: claim-id})
        claim-data (ok claim-data)
        ERR-NOT-FOUND
    )
)

;; Get claimant profile
(define-read-only (get-claimant-profile (claimant principal))
    (match (map-get? claimant-profiles {claimant: claimant})
        profile (ok profile)
        ERR-NOT-FOUND
    )
)

;; Get payout information
(define-read-only (get-payout-info (claim-id uint))
    (match (map-get? claim-payouts {claim-id: claim-id})
        payout (ok payout)
        ERR-NOT-FOUND
    )
)

;; Check if claim type is valid
(define-read-only (is-valid-claim-type (claim-type uint))
    (or 
        (is-eq claim-type CLAIM-TYPE-MEDICAL)
        (or
            (is-eq claim-type CLAIM-TYPE-UNEMPLOYMENT)
            (or
                (is-eq claim-type CLAIM-TYPE-DISABILITY)
                (is-eq claim-type CLAIM-TYPE-EMERGENCY)
            )
        )
    )
)

;; Get maximum claim amount for type
(define-read-only (get-max-claim-amount (claim-type uint))
    (if (is-eq claim-type CLAIM-TYPE-MEDICAL)
        MAX-MEDICAL-CLAIM
        (if (is-eq claim-type CLAIM-TYPE-UNEMPLOYMENT)
            MAX-UNEMPLOYMENT-CLAIM
            (if (is-eq claim-type CLAIM-TYPE-DISABILITY)
                MAX-DISABILITY-CLAIM
                (if (is-eq claim-type CLAIM-TYPE-EMERGENCY)
                    MAX-EMERGENCY-CLAIM
                    u0
                )
            )
        )
    )
)

;; Calculate approval rate for verifier
(define-read-only (calculate-approval-rate (verifier principal) (current-approve bool))
    (let
        (
            (verifier-info (unwrap! (map-get? authorized-verifiers {verifier: verifier}) u0))
            (current-count (get verification-count verifier-info))
            (current-rate (get approval-rate verifier-info))
        )
        (if (is-eq current-count u0)
            (if current-approve u100 u0)
            (let
                (
                    (total-approvals (/ (* current-rate current-count) u100))
                    (new-approvals (if current-approve (+ total-approvals u1) total-approvals))
                    (new-count (+ current-count u1))
                )
                (/ (* new-approvals u100) new-count)
            )
        )
    )
)

;; Get system statistics
(define-read-only (get-system-stats)
    (ok {
        total-claims: (var-get total-claims-submitted),
        approved-claims: (var-get total-claims-approved),
        total-paid: (var-get total-amount-paid),
        reserve-balance: (var-get system-reserve-balance),
        approval-rate: (if (> (var-get total-claims-submitted) u0)
                         (/ (* (var-get total-claims-approved) u100) (var-get total-claims-submitted))
                         u0)
    })
)

;; Administrative functions
(define-public (authorize-verifier (verifier principal) (specialization uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        (map-set authorized-verifiers
            {verifier: verifier}
            {
                is-active: true,
                verification-count: u0,
                approval-rate: u0,
                specialization: specialization,
                authorization-block: stacks-block-height
            }
        )
        (ok true)
    )
)

;; Update system reserve balance
(define-public (update-reserve-balance (new-balance uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set system-reserve-balance new-balance)
        (ok true)
    )
)

