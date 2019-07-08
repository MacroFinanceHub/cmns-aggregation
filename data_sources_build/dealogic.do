* --------------------------------------------------------------------------------------------------
* Dealogic_Build: This file build the ultimate-parent aggregation data from Dealogic, which is
* used as input in the CMNS aggregation procedure.
* --------------------------------------------------------------------------------------------------
cap log close
log using "$logs/${whoami}_Dealogic_Build", replace

* Process CIQ identifiers
use "$raw/ciq/wrds_cusip.dta", clear
replace enddate = td(31dec2099) if missing(enddate)
bysort companyid: egen max_enddate = max(enddate)
keep if enddate == max_enddate
gen ciq_issuer_number = substr(cusip, 1, 6)
keep companyid ciq_issuer_number
duplicates drop

* Take the first since these will all be caught by the AI file later
collapse (firstnm) ciq_issuer_number, by(companyid)
rename companyid CapiqId
save "$temp/ciq_identifiers_for_dealogic_merge.dta", replace

* Process company listings
use "$raw/dealogic/companylistings.dta", clear
rename isin ISIN
rename companyid Id
replace ISIN = "" if ISIN == "nan"
keep Id ISIN
save "$temp/isin_for_dealogic_merge.dta", replace

* Process ISINs
use "$tempcgs/allmaster_essentials_isin.dta", clear
keep isin issuer_num
rename isin ISIN
rename issuer_num isin_issuer_number
save "$temp/isin_mapping_for_dealogic.dta", replace

* Run CIQ match
use "$raw/dealogic/company.dta", clear
rename cusip CUSIP
rename capiqid CapiqId
rename id Id
mmerge CapiqId using "$temp/ciq_identifiers_for_dealogic_merge.dta", unmatched(m)
replace CUSIP = ciq_issuer_number if missing(CUSIP) & ~missing(ciq_issuer_number)
mmerge Id using "$temp/isin_for_dealogic_merge.dta", unmatched(m)
mmerge ISIN using "$temp/isin_mapping_for_dealogic.dta", unmatched(m)
replace CUSIP = isin_issuer_number if missing(CUSIP) & ~missing(isin_issuer_number)
save "$temp/company_build_tmp.dta", replace

* Process tranche ISINS
use "$raw/dealogic/dcmdealtranchesisins.dta", clear
rename dcmdealtranchetrancheid trancheid
rename dcmdealtranchedealid dealid
sort dealid trancheid
save "$temp/dcmdealtranchesisins.dta", replace

* Merge tranche id's
use "$raw/dealogic/dcmdealtranches.dta", clear
keep dcmdealdealid trancheid cusip
rename dcmdealdealid dealid
rename cusip CUSIP
mmerge dealid trancheid using "$temp/dcmdealtranchesisins.dta", unmatched(m)
drop _merge
mmerge dealid using "$raw/dealogic/dcmdeal.dta", unmatched(m) ukeep(issuerid)
drop _merge
replace CUSIP = substr(CUSIP, 1, 6)
mmerge isin using "$temp/isin_mapping_for_dealogic.dta", unmatched(m) umatch(ISIN)
replace CUSIP = isin_issuer_number if missing(CUSIP) & ~missing(isin_issuer_number)
drop _merge
cap drop sortnumber
keep if ~missing(CUSIP)
keep CUSIP issuerid
duplicates drop
save "$temp/dcmdealtranches.dta", replace

use "$temp/company_build_tmp.dta", clear
keep Id companyparentid CUSIP name nationalityofincorporationisocod nationalityofbusinessisocode 
append using "$temp/dcmdealtranches.dta"
replace companyparentid = issuerid if missing(companyparentid) & ~missing(issuerid)
drop issuerid
replace companyparentid = Id if missing(companyparentid)
save "$temp/company_build_tmp2.dta", replace
mmerge companyparentid using "$temp/company_build_tmp2.dta", unmatched(m) umatch(Id) ukeep(CUSIP name nationality*) uname(p_)
keep if ~missing(CUSIP) & ~missing(p_CUSIP)
drop _merge Id companyparentid
duplicates drop CUSIP p_CUSIP, force
drop if CUSIP == p_CUSIP & missing(nationalityofbusinessisocode) & missing(nationalityofincorporationisocod)
save "$temp/dealogic_aggregation_tmp.dta", replace

* Use CGS associated issuer file to tidy up conflicts
use "$temp/dealogic_aggregation_tmp.dta", clear
mmerge CUSIP using "$aggregation_sources/cgs_ai_aggregation.dta", unmatched(m) umatch(issuer_num) uname(ai_)
duplicates tag CUSIP, gen(_dup)
replace p_CUSIP = ai_ai_parent_issuer_num if ~missing(ai_ai_parent_issuer_num) & _dup > 0
replace p_name	= ai_ai_parent_issuer_name if ~missing(ai_ai_parent_issuer_num) & _dup > 0
replace p_nationalityofbusinessisocode = ai_ai_parent_domicile if ~missing(ai_ai_parent_issuer_num) & _dup > 0
replace p_nationalityofincorporationisoc = ai_ai_parent_domicile if ~missing(ai_ai_parent_issuer_num) & _dup > 0
drop ai_* _merge _dup
duplicates drop CUSIP p_CUSIP, force

* We still have some unresolved CUSIPs that map to different parents; we
* drop these. These look mostly like cases in which M&A activity took place
duplicates tag CUSIP, gen(_dup)
drop if _dup > 0
drop _dup
save "$temp/dealogic_aggregation_file.dta", replace
keep p_CUSIP p_nationalityofbusinessisocode 
bysort p_CUSIP: gen _dup = _N
keep if _dup > 1
drop _dup
gen _drop = 1
duplicates drop p_CUSIP, force
save "$temp/p_cusip_for_drop.dta", replace

use "$temp/dealogic_aggregation_file.dta", clear
mmerge p_CUSIP using "$temp/p_cusip_for_drop.dta", unmatched(m)
drop if _drop == 1
cap drop _drop
cap drop _merge

* Add everything to LHS
rename CUSIP _CUSIP
mmerge _CUSIP using "$temp/dealogic_aggregation_file.dta", umatch(p_CUSIP) unmatched(b) uname(u_)
replace name = u_p_name if _merge == 2
replace nationalityofb = u_p_nationalityofb if _merge == 2
replace nationalityofi = u_p_nationalityofi if _merge == 2
replace p_CUSIP = _CUSIP if _merge == 2
replace p_name = name if _merge == 2
replace p_nationalityofb = nationalityofb if _merge == 2
replace p_nationalityofi = nationalityofi if _merge == 2
drop u_*
rename _CUSIP CUSIP
drop _merge
gen CUSIP_len = strlen(trim(CUSIP))
drop if CUSIP_len != 6
drop CUSIP_len
duplicates drop CUSIP p_CUSIP, force
keep CUSIP name p_CUSIP p_name p_nationalityofbusinessisocode
rename CUSIP cusip6
rename name issuer_name
rename p_name up_issuer_name
rename p_CUSIP up_cusip6
rename p_nationalityofbusinessisocode country_dlg
save "$aggregation_sources/dealogic_aggregation.dta", replace

log close
