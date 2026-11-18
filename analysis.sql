/* =====================================================================
   Lending Club: Setting the Approval Cutoff for a Lender
   ---------------------------------------------------------------------
   Question: At what risk grade should a lender stop approving loans
             to maximise profit?
   Data:     Lending Club accepted loans, 2007-2018 (Kaggle), imported
             into SQLite as the table "loans" (about 2.26 million rows)
   Tool:     SQLite (DB Browser for SQLite)
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. Explore the data
   --------------------------------------------------------------------- */

-- Total number of loans in the table
SELECT COUNT(*) AS total_loans
FROM loans;

-- Number of loans in each status.
-- Only some statuses show how a loan ended, so this decides which loans can be used.
SELECT loan_status,
       COUNT(*) AS num_loans
FROM loans
GROUP BY loan_status
ORDER BY num_loans DESC;


/* ---------------------------------------------------------------------
   2. Keep only finished loans
   ---------------------------------------------------------------------
   Loans still being repaid ("Current", "Late", "In Grace Period" and
   "Default") have no final outcome yet, so they are excluded. Counting
   them as "not defaulted" would understate default rates.
   The older "Does not meet the credit policy" loans are kept, because
   their final status (Fully Paid or Charged Off) is known.
   --------------------------------------------------------------------- */

-- Saved view of finished loans, with a 1/0 column showing whether each loan defaulted
CREATE VIEW IF NOT EXISTS finished_loans AS
SELECT *,
       CASE
         WHEN loan_status LIKE '%Charged Off' THEN 1   -- defaulted ("Charged Off")
         ELSE 0                                         -- repaid in full
       END AS defaulted
FROM loans
WHERE loan_status IN (
  'Fully Paid',
  'Charged Off',
  'Does not meet the credit policy. Status:Fully Paid',
  'Does not meet the credit policy. Status:Charged Off'
);

-- Check: number of finished loans and defaults
-- Result: 1,348,059 finished loans and 269,320 defaults (about 20%)
SELECT COUNT(*) AS num_loans,
       SUM(defaulted) AS num_defaults
FROM finished_loans;


/* ---------------------------------------------------------------------
   3. Default rate by grade
   ---------------------------------------------------------------------
   Because "defaulted" is 1 or 0, SUM gives the number of defaults and
   AVG gives the share of loans that defaulted (defaults / loans).
   --------------------------------------------------------------------- */

SELECT grade,
       COUNT(*) AS num_loans,
       SUM(defaulted) AS num_defaults,
       ROUND(AVG(defaulted) * 100, 1) AS default_rate_pct
FROM finished_loans
GROUP BY grade
ORDER BY grade;

-- Finding: default rates rose steadily with risk grade, from 6% for grade A
-- to almost 50% for grade G, showing that Lending Club's grades ranked risk well.


/* ---------------------------------------------------------------------
   4. Default rate by vintage (year the loan was issued)
   ---------------------------------------------------------------------
   issue_d is stored as text such as "Dec-2015", so SUBSTR(issue_d, -4)
   takes the last 4 characters to get the year.
   --------------------------------------------------------------------- */

-- 4a. Default rate by year, all finished loans
SELECT SUBSTR(issue_d, -4) AS issue_year,
       COUNT(*) AS num_loans,
       SUM(defaulted) AS num_defaults,
       ROUND(AVG(defaulted) * 100, 1) AS default_rate_pct
FROM finished_loans
GROUP BY issue_year
ORDER BY issue_year;

-- Caution: the data is a snapshot taken at the end of 2018, so many recent loans
-- had not finished. Early payoffs appear quickly while defaults take months to be
-- recorded, which distorts default rates for loans issued from about 2014 onwards.

-- 4b. Loan terms offered and the years they were issued
-- Result: 3-year loans from 2007, 5-year loans from 2010
SELECT term,
       MIN(CAST(SUBSTR(issue_d, -4) AS INTEGER)) AS first_year,
       MAX(CAST(SUBSTR(issue_d, -4) AS INTEGER)) AS last_year,
       COUNT(*) AS num_loans
FROM loans
WHERE term IS NOT NULL
GROUP BY term;

/* To compare years like-for-like, the next queries use only matured loans:
   3-year loans issued up to 2015, which were all due to finish by the end
   of 2018. 3-year loans are used because they cover more years (2007-2015)
   than 5-year loans (2010-2013), make up most of the data, and avoid mixing
   loan lengths with different levels of risk. */

-- 4c. Check: had nearly all of these loans finished by the end of 2018?
-- Uses the full "loans" table, since the view has already removed unfinished loans.
-- Result: only 147 of 621,169 loans (0.02%) were unfinished, so the group is complete.
SELECT loan_status,
       COUNT(*) AS num_loans
FROM loans
WHERE term = '36 months'
  AND CAST(SUBSTR(issue_d, -4) AS INTEGER) <= 2015   -- CAST turns the text year into a number
GROUP BY loan_status
ORDER BY num_loans DESC;

-- 4d. Like-for-like comparison: all finished loans vs matured 3-year loans, by year
-- CASE WHEN keeps the defaulted value only for 3-year loans; AVG ignores the blanks.
SELECT SUBSTR(issue_d, -4) AS issue_year,
       ROUND(AVG(defaulted) * 100, 1) AS all_finished_pct,
       ROUND(AVG(CASE WHEN term = '36 months' THEN defaulted END) * 100, 1) AS matured_3yr_pct
FROM finished_loans
WHERE CAST(SUBSTR(issue_d, -4) AS INTEGER) <= 2015
GROUP BY issue_year
ORDER BY issue_year;

-- Finding: among matured 3-year loans, default rates peaked during the 2007-2008
-- financial crisis (21-26%), were lowest for 2010-2011 loans (about 11%), and rose
-- gradually to about 15% by 2015. The sharper rise across all finished loans (to
-- about 20%) was mostly caused by including loans that had not yet run their full term.


/* ---------------------------------------------------------------------
   5. Loss given default by grade
   ---------------------------------------------------------------------
   When a loan defaults, what share of the amount lent is actually lost?
   Loss = amount lent - principal repaid - recoveries + collection costs
   --------------------------------------------------------------------- */

SELECT grade,
       COUNT(*) AS num_defaults,
       ROUND(AVG(funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee)
             / AVG(funded_amnt) * 100, 1) AS lgd_pct
FROM finished_loans
WHERE defaulted = 1
GROUP BY grade
ORDER BY grade;

-- Finding: on defaulted loans, lenders lost between 54% (grade A) and 78% (grade G)
-- of the amount lent, as riskier borrowers tended to default earlier.


/* ---------------------------------------------------------------------
   6. Expected loss by grade
   ---------------------------------------------------------------------
   Expected loss = probability of default x loss given default x exposure,
   calculated as total losses divided by total amount lent, and shown as
   dollars lost per $100 lent.
   --------------------------------------------------------------------- */

SELECT grade,
       COUNT(*) AS num_loans,
       ROUND(AVG(defaulted) * 100, 1) AS pd_pct,
       ROUND(SUM(CASE WHEN defaulted = 1
                      THEN funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee
                      ELSE 0 END)                      -- loss on each loan (0 if repaid)
             / SUM(funded_amnt) * 100, 1) AS expected_loss_pct
FROM finished_loans
GROUP BY grade
ORDER BY grade;

-- Finding: for every $100 lent, lenders lost about $3 on grade A, $15 on grade C
-- and $38.50 on grade G.


/* ---------------------------------------------------------------------
   7. Profit by grade
   ---------------------------------------------------------------------
   Profit = everything received back - collection costs - amount lent,
   shown as dollars per $100 lent. Profit should roughly equal interest
   minus losses, which serves as a check on the calculation.
   --------------------------------------------------------------------- */

SELECT grade,
       COUNT(*) AS num_loans,
       ROUND(SUM(total_rec_int + total_rec_late_fee)
             / SUM(funded_amnt) * 100, 1) AS interest_pct,      -- interest and late fees earned
       ROUND(SUM(CASE WHEN defaulted = 1
                      THEN funded_amnt - total_rec_prncp - recoveries + collection_recovery_fee
                      ELSE 0 END)
             / SUM(funded_amnt) * 100, 1) AS loss_pct,           -- money lost on defaults
       ROUND(SUM(total_rec_prncp + total_rec_int + total_rec_late_fee + recoveries
                 - collection_recovery_fee - funded_amnt)
             / SUM(funded_amnt) * 100, 1) AS profit_pct          -- overall profit
FROM finished_loans
GROUP BY grade
ORDER BY grade;

-- Finding: grades A to C were profitable, grade D roughly broke even, and grades
-- E to G lost money, because their higher interest did not cover their losses.
-- Limitation: this measure ignores platform fees and the time value of money.


/* ---------------------------------------------------------------------
   8. Profit curve: approving grades A up to each cutoff
   ---------------------------------------------------------------------
   If the lender only approved grades up to a given letter, how much
   profit would it make?
   - WITH builds a temporary table of totals for each grade.
   - SUM(...) OVER (ORDER BY grade) gives a running total, so each row
     shows the result of approving that grade and every grade before it.
   - SUM(...) OVER () gives the grand total across all grades.
   Results exported to profit_curve.csv for the Excel chart.
   --------------------------------------------------------------------- */

WITH by_grade AS (
  SELECT grade,
         COUNT(*) AS num_loans,
         SUM(funded_amnt) AS amount_lent,
         SUM(total_rec_prncp + total_rec_int + total_rec_late_fee + recoveries
             - collection_recovery_fee - funded_amnt) AS profit
  FROM finished_loans
  GROUP BY grade
)
SELECT grade AS cutoff_grade,
       -- share of all loans approved up to this grade
       ROUND(SUM(num_loans) OVER (ORDER BY grade) * 100.0
             / SUM(num_loans) OVER (), 1) AS approval_rate_pct,
       -- total profit up to this grade, in millions of dollars
       ROUND(SUM(profit) OVER (ORDER BY grade) / 1000000, 1) AS total_profit_millions,
       -- profit for every $100 lent up to this grade
       ROUND(SUM(profit) OVER (ORDER BY grade) * 100.0
             / SUM(amount_lent) OVER (ORDER BY grade), 1) AS profit_per_100_lent
FROM by_grade
ORDER BY grade;

-- Finding: total profit peaked at a grade D cutoff ($577M), but a grade C cutoff
-- captured 99.4% of that ($573.8M) while approving 75% of applicants instead of 90%.
-- Recommendation: set the approval cutoff at grade C, since grade D's small extra
-- profit would likely disappear once fees and funding costs are included.
-- Approving every grade would have cost about $76M in profit.
