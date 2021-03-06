##
## Preprocess data for Shiny dashboard
##
library(tidyverse)
library(lubridate)
library(readxl)
library(nomisr)
library(httr)
library(sf)
library(jsonlite)

# Local Authority Districts Names and Codes in the United Kingdom
lads = read_csv("https://opendata.arcgis.com/datasets/35de30c6778b463a8305939216656132_0.csv")

# ---- Vulnerability Index ----
vi = read_sf("https://github.com/britishredcrosssociety/covid-19-vulnerability/raw/master/output/vulnerability-MSOA-UK.geojson")

# lookup local authorities that each MSOA is in
msoa_lad = read_csv("https://github.com/britishredcrosssociety/covid-19-vulnerability/raw/master/data/lookup%20msoa%20to%20lad.csv")

# save a local copy
vi %>% 
  left_join(msoa_lad, by = c("Code" = "MSOA11CD")) %>% 
  write_sf("data/vulnerability.geojson")

# ---- Weekly infection rates ----
# Fetch National COVID-19 surveillance data report from https://www.gov.uk/government/publications/national-covid-19-surveillance-reports
# This URL corresponds to 11 September 2020 (week 37):
GET("https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/916998/Weekly_COVID19_report_data_w37.xlsx",
    write_disk(tf <- tempfile(fileext = ".xlsx")))

covid = read_excel(tf, sheet = "Figure 11. All weeks rates UTLA", skip = 7)

# Clean the data
covid = covid %>% 
  select(LAD19CD = `UTLA code`, starts_with("week")) %>% 
  filter(str_sub(LAD19CD, 1, 1) == "E") %>% 
  mutate(across(starts_with("week"), as.numeric))


# Hackney and City of London boroughs are counted as one. Split into separate rows, using the same data for each
covid = bind_rows(covid %>% filter(LAD19CD != "E09000012/E09000001"),
                  covid %>% filter(LAD19CD == "E09000012/E09000001") %>% mutate(LAD19CD = "E09000012"),
                  covid %>% filter(LAD19CD == "E09000012/E09000001") %>% mutate(LAD19CD = "E09000001"))


# Calculate average rate for past three weeks, plus get latest rate
covid_sum = covid %>% 
  rowwise() %>% 
  mutate(`Mean infection rate over last 3 weeks` = mean(c_across((ncol(covid) - 2):ncol(covid)), na.rm = TRUE)) %>% 
  mutate(`SD infection rate over last 3 weeks` = sd(c_across((ncol(covid) - 2):ncol(covid)), na.rm = TRUE)) %>% 
  mutate(`upper`=`Mean infection rate over last 3 weeks` + `SD infection rate over last 3 weeks`) %>%
  mutate(`lower`=`Mean infection rate over last 3 weeks` - `SD infection rate over last 3 weeks`) %>%
  select(LAD19CD, `Latest infection rate` = ncol(covid), `Mean infection rate over last 3 weeks`, `upper`, `lower`)

#print(covid_sum)

covid_raw = lads %>% 
  select(LAD19CD, Name = LAD19NM) %>% 
  left_join(covid, by = "LAD19CD")

#renaming so will match with england avg.
covid_raw <- rename_with(covid_raw, ~ gsub("week 0", "", .x, fixed = TRUE))
covid_raw <- rename_with(covid_raw, ~ gsub("week ", "", .x, fixed = TRUE))


unlink(tf); rm(tf)

# ----- England cases per 100,000 per week ------
# https://coronavirus.data.gov.uk/
# API guide
# https://coronavirus.data.gov.uk/developers-guide 
AREA_TYPE = "nation"
AREA_NAME = "england"

endpoint <- "https://api.coronavirus.data.gov.uk/v1/data"

# Create filters:
filters <- c(
  sprintf("areaType=%s", AREA_TYPE),
  sprintf("areaName=%s", AREA_NAME)
)

# Create the structure as a list or a list of lists:
structure <- list(
  date  = "date", 
  name  = "areaName", 
  code  = "areaCode", 
  cases = list(
    daily = "newCasesByPublishDate")
)

# The "httr::GET" method automatically encodes 
# the URL and its parameters:
httr::GET(
  # Concatenate the filters vector using a semicolon.
  url = endpoint,
  
  # Convert the structure to JSON (ensure 
  # that "auto_unbox" is set to TRUE).
  query = list(
    filters   = paste(filters, collapse = ";"),
    structure = jsonlite::toJSON(structure, auto_unbox = TRUE)
  ),
  
  # The API server will automatically reject any
  # requests that take longer than 10 seconds to 
  # process.
  timeout(10)
) -> response

# Handle errors:
if (response$status_code >= 400) {
  err_msg = httr::http_status(response)
  stop(err_msg)
}

# Convert response from binary to JSON:
json_text <- content(response, "text")
daily_cases_eng <- jsonlite::fromJSON(json_text)
daily_cases_eng <- daily_cases_eng$data


# for this example remove first four rows to make the weeks correct
daily_cases_eng <- daily_cases_eng[-c(1:4),]
daily_cases_eng$week <- week(daily_cases_eng$date)

# sum by week - divide by population * 100,000 to get cases per 100000 for each week
#ONS population of england: https://www.ons.gov.uk/peoplepopulationandcommunity/populationandmigration/populationestimates#:~:text=The%20UK%20population%20was%20estimated,the%20year%20to%20mid%2D2018.
eng_cases_per_100000 <- daily_cases_eng %>% group_by(week) %>% summarise(week_cases_per_100000=round((sum(cases)/66796800)*100000,2))

# Match weeks to covid_raw
eng_cases_per_100000 <- eng_cases_per_100000[-37,]
eng_cases_per_100000 <- eng_cases_per_100000[-c(1:4),]

#to merge with covid raw 
eng_cases_per_100000_wide <- eng_cases_per_100000 %>% pivot_wider(c(week), names_from=week, values_from=week_cases_per_100000)
eng_cases_per_100000_wide <- eng_cases_per_100000_wide %>% mutate(LAD19CD='England',.before=`5`) %>% mutate(Name='England',.before=`5`)

#print(eng_cases_per_100000_wide)
#add row to covid raw
covid_raw = covid_raw %>% add_row(eng_cases_per_100000_wide)

#write to file
write_csv(covid_raw, 'data/all_covid_infection_rate_data.csv')

# ---- Shielding ----
# Coronavirus Shielded Patient List, England - Local Authority: https://digital.nhs.uk/data-and-information/publications/statistical/mi-english-coronavirus-covid-19-shielded-patient-list-summary-totals/latest
shielded = read_csv("https://files.digital.nhs.uk/BC/85E39A/Coronavirus%20Shielded%20Patient%20List%2C%20England%20-%20Open%20Data%20with%20CMO%20DG%20-%20LA%20-%202020-09-09.csv")

shielded = shielded %>% 
  # keep only latest values (if more than one extraction happens to be in this file)
  mutate(`Extract Date` = dmy(`Extract Date`)) %>% 
  filter(`Extract Date` == max(`Extract Date`)) %>% 
  
  filter(`LA Code` != "ENG") %>%  # don't need England-wide figures
  filter(`Breakdown Field` == "ALL") %>%  #don't need age/gender splits
  
  select(LAD19CD = `LA Code`, `Clinically extremely vulnerable` = `Patient Count`)


# ---- Ethnicity ----
##
## Load LA-level data from the Annual Population Survey:
## - Percentage of population who are {white or ethnic minority} and {UK born or not}
## - Percentage of working-age population who are {white or ethnic minority} and {UK born or not}
## - Unemployment rate: {white or ethnic minority} and {UK born or not}
## - Economic inactivity rate: {white or ethnic minority} and {UK born or not}
##
## Based on this URL: https://www.nomisweb.co.uk/api/v01/dataset/NM_17_5.jsonstat.json?geography=1811939329...1811939332,1811939334...1811939336,1811939338...1811939497,1811939499...1811939501,1811939503,1811939505...1811939507,1811939509...1811939517,1811939519,1811939520,1811939524...1811939570,1811939575...1811939599,1811939601...1811939628,1811939630...1811939634,1811939636...1811939647,1811939649,1811939655...1811939664,1811939667...1811939680,1811939682,1811939683,1811939685,1811939687...1811939704,1811939707,1811939708,1811939710,1811939712...1811939717,1811939719,1811939720,1811939722...1811939730,943718401...943718419,943718421...943718463,943718465...943718497,943718499...943718512,943718420,943718464,943718498&date=latest&variable=861...868,873...880&measures=20599,21001,21002,21003
##
aps_raw = nomis_get_data(
  id = "NM_17_5",
  date = "latest",
  geography = "TYPE432",  # 2019 LAD
  variable = "861...864",  # "861...868,873...880",
  measures = "20599,21001,21002,21003",
  
  # variables to keep
  select = c(
    "GEOGRAPHY_CODE",
    "VARIABLE_NAME",
    "MEASURES_NAME",
    "OBS_VALUE"
  )
)

aps = aps_raw %>% 
  filter(MEASURES_NAME == "Variable") %>% 
  select(LAD19CD = GEOGRAPHY_CODE, Variable = VARIABLE_NAME, Value = OBS_VALUE) %>% 
  pivot_wider(names_from = Variable, values_from = Value)


# ---- Asylum ----
# download the latest stats on Section 95 support by local authority - https://www.gov.uk/government/statistical-data-sets/asylum-and-resettlement-datasets
# https://www.gov.uk/government/statistical-data-sets/asylum-and-resettlement-datasets
#  This URL corresponds to data from June 2020:
GET("https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/910573/section-95-support-local-authority-datasets-jun-2020.xlsx",
    write_disk(tf <- tempfile(fileext = ".xlsx")))

asylum_raw = read_excel(tf, sheet = "Data - Asy_D11")  # check the sheet name is still valid if you're updating the URL above

# convert date column
asylum = asylum_raw %>% 
  mutate(Date = as.Date(`Date (as at…)`, format = "%d %b %Y"))

# get rid of rows with totals and keep only LADs with refugees
asylum = asylum %>% 
  filter(Date == max(asylum$Date)) %>% 
  select(LAD19CD = `LAD Code`, Support = `Support sub-type`, People) %>% 
  pivot_wider(names_from = Support, values_from = People, values_fn = list(People = sum), values_fill = list(People = 0)) %>% 
  
  mutate(`People receiving Section 95 support` = `Dispersed Accommodation` + `Subsistence Only`)

unlink(tf); rm(tf)

# ---- Deprivation ----
## Load LA-level deprivation scores
## - from: https://www.gov.uk/government/statistics/english-indices-of-deprivation-2019
## - source: File 10: local authority district summaries
##
## We'll use two summary measures of deprivation in LAs: extent and proportion of Lower-layer Super Output Areas in most deprived 10% nationally
## - extent =  the proportion of the local population that live in areas classified as among the most deprived in the country
## 
## (see Table 3.2 in the IMD technical report for more details: https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/833951/IoD2019_Technical_Report.pdf)
##
GET("https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/833995/File_10_-_IoD2019_Local_Authority_District_Summaries__lower-tier__.xlsx",
    write_disk(tf_imd <- tempfile(fileext = ".xlsx")))

imd = read_excel(tf_imd, sheet = "IMD") 

imd = imd %>% 
  select(LAD19CD = `Local Authority District code (2019)`, `IMD 2019 - Extent`)

unlink(tf_imd); rm(tf_imd)


# ---- Merge and save ----
la_data = lads %>% 
  select(LAD19CD, Name = LAD19NM) %>% 
  left_join(covid_sum, by = "LAD19CD") %>% 
  left_join(shielded, by = "LAD19CD") %>% 
  left_join(imd, by = "LAD19CD") %>% 
  left_join(aps, by = "LAD19CD") %>% 
  left_join(asylum, by = "LAD19CD")

write_csv(la_data, "data/local authority stats.csv")
