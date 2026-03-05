# Notes on the Task

We have at least the following data sets. What we want to do is

1. validated that the data is good enough to analyze. Sometimes there are just straight up fake datasets on Kaggle, so you want to verify what we have here.

2. Examine the papers published on the data to understand the major scientific objectives people have already attacked with these data sets.

3. Do a bit of preliminary data analysis to help determine what directions we should suggest to the datathon teams.

4. Figure out what software you need to analyze the data set so I can add them to our environment.

5. Determine whether any pre-trained models would be useful.

# Research uses of selected public‑health datasets

## Stroke prediction dataset  
The Kaggle stroke prediction dataset offers anonymous demographic and clinical profiles for about 5 110 patients with 11–12 features (age, sex, hypertension and heart‑disease history, marital status, work type, residence type, smoking status, average glucose level and body‑mass index) along with a binary label indicating whether the patient experienced a stroke.  Researchers use this dataset primarily to develop classification models and explore risk factors:

- **Predictive modelling and identification of key risk factors for stroke (Hassan et al., 2024)** – This study addresses missing values and severe class imbalance by applying several imputation strategies and the Synthetic Minority Over‑Sampling Technique.  It compares multiple classifiers and identifies age, body‑mass index, average glucose level, heart disease, hypertension and marital status as the most influential predictors.  A dense stacking ensemble achieved >96 % accuracy with an AUC of 83.9 % on the imbalanced .  The objective is to improve early detection of stroke by refining model architecture and handling class imbalance.
- **Visual analysis and prediction of stroke (Carnegie Mellon University, 2021)** – A student capstone project performs exploratory data analysis, categorical encoding and undersampling to balance the highly imbalanced classes.  The research questions include identifying attributes associated with stroke, applying principal component analysis and comparing clustering and decision‑tree classifiers.  The project concludes that age, average glucose level, hypertension and smoking history are key variables.

These works show that the stroke dataset is used to investigate risk factors and develop classification models that address missing data and class imbalance.

## Novel coronavirus 2019 time‑series data  
DataHub’s COVID‑19 dataset aggregates daily counts of confirmed cases, deaths and recoveries worldwide, cleaning and normalising information from sources like the World Health Organization, Johns Hopkins University CSSE and national health agencies.  Researchers rely on this dataset for time‑series forecasting and evaluation of public‑health interventions:

- **COVID‑19 pandemic: ARIMA and regression model‑based worldwide death‑case predictions (Chaurasia & Pal, 2020)** – Using DataHub’s dataset covering January 22–June 29 2020, the authors build ARIMA and regression models to estimate global COVID‑19 deaths.  Error metrics (MAE, MSE, RMSE and MAPE) indicate that mortality rates declined after May 2020 and that short‑term forecasts could aid governments in planning interventions.
- **Dataset documentation** – DataHub’s own documentation emphasises that it tracks confirmed cases, deaths and recoveries by country, normalises date formats and consolidates multiple files into consistent time series.  Researchers cite this documentation to justify data provenance and cleaning.

The COVID‑19 dataset is thus used to forecast case trends, evaluate models and inform public‑health planning.

## Diabetes health indicators (BRFSS 2015 subset)  
The Diabetes Health Indicators dataset is a cleaned and balanced subset of the CDC’s 2015 Behavioral Risk Factor Surveillance System (BRFSS), containing 253 680 survey responses with 21–35 features—blood pressure, cholesterol check, BMI, smoking history, physical activity, fruit and vegetable intake and other lifestyle variables.  Studies aim to improve early detection of type 2 diabetes and identify key risk factors:

- **Ensemble learning for diabetes classification (Arman et al., 2025)** – Combining predictions from five classifiers (XGBoost, Random Forest, Gradient Boosting, Support Vector Machine and a CNN‑LSTM model) using soft voting, the ensemble achieves 87.8 % accuracy and an F1‑score of 0.992.  The goal is to enhance early detection and support patient management through ensemble methods.
- **Detecting high‑risk factors and early diagnosis of diabetes using machine‑learning methods (Ullah et al., 2022)** – This paper employs SMOTE‑ENN to balance classes and evaluates multiple algorithms, reporting that k‑nearest neighbours and other models achieve high accuracy (AUC around 98.38 %).  It identifies obesity, age, insulin resistance and hypertension as key risk factors, emphasising the value of machine learning for early diagnosis.

These examples demonstrate that researchers use the BRFSS subset to develop predictive models for type 2 diabetes, address class imbalance and pinpoint lifestyle and medical risk factors.

## Heart failure clinical records dataset  
This dataset from the UCI Machine Learning Repository contains medical records of 299 heart‑failure patients with 13 features—age, anaemia, creatinine‑phosphokinase, diabetes, ejection fraction, high blood pressure, platelets, serum creatinine, serum sodium, sex, smoking status, follow‑up time and a binary outcome indicating death during follow‑up.  Researchers use it to predict survival and explore prognostic factors:

- **Heart failure survival prediction using novel transfer‑learning‑based probabilistic features (Qadri et al., 2024)** – Analyzing 299 patient records, the authors address class imbalance using SMOTE and propose transfer‑learning‑based features derived from ensemble trees.  A random‑forest model with these features achieves 97.5 % accuracy, demonstrating strong prognostic performance.  The objective is to develop robust survival prediction models and provide personalized prognostic assessments.
- **Survival analysis and machine‑learning models for predicting heart‑failure outcomes (AlQahtani & Algarni, 2025)** – This study combines Cox proportional hazards survival analysis with machine‑learning classification.  Using feature scaling, imputation and class balancing, the authors build Cox models and train K‑nearest neighbours, decision trees and random forests to predict outcomes.  The random‑forest classifier with Cox‑selected features achieves 96.2 % accuracy and an AUC of 0.987, showing that integrating survival analysis with ML improves prediction accuracy.

These works illustrate that the heart‑failure dataset is used to build survival prediction models, employ advanced feature engineering and transfer learning and address small sample size and class imbalance.

## NHANES dataset  
The National Health and Nutrition Examination Survey (NHANES) is a nationally representative program conducted by the U.S. National Center for Health Statistics.  Using multistage, stratified probability sampling, NHANES collects health interviews and physical examinations from about 5 000 individuals each year, oversampling certain populations to ensure representativeness.  The 1999‑2018 cycles included 116 876 participants; after excluding minors and missing data, 40 298 adults were analysed in some studies.  Researchers employ NHANES data to develop machine‑learning models for cardiovascular and metabolic risk prediction:

- **Interpretable machine learning model for ASCVD identification (Tang et al., 2025)** – This study constructed machine‑learning models to correlate demographic and dietary patterns with atherosclerotic cardiovascular disease (ASCVD).  Using NHANES data from 1999–2018, the authors analysed 40 298 participants and developed five models, selecting XGBoost for its superior performance (AUC 0.8143; accuracy 88.4 %).  Male sex, older age and smoking showed positive associations with ASCVD, whereas dairy intake displayed a negative correlation.  Because the data were highly imbalanced (around 9:1), they employed the SMOTE‑ENN technique to oversample minority cases before model training.
- **Machine learning‑driven risk assessment of coronary heart disease (Lu et al., 2024)** – An analysis of 49 490 adults from NHANES 1999‑2018 selected 68 variables and used random forest and XGBoost for variable selection.  A logistic regression model incorporating six key variables—age, serum creatinine, platelet count, glycated haemoglobin, uric acid and the coefficient of variation of red cell distribution width—was developed to predict coronary heart disease.  The model achieved an AUC of 0.841 and demonstrated stable calibration and clinical utility.  This work shows how ML can identify novel risk factors and construct practical risk scores for coronary heart disease.
- **Interpretable machine learning for cardiovascular risk prediction (Ahiduzzaman & Hasan, 2025)** – This PLOS One study used NHANES 2017–2023 data (12 382 adults, 41 dietary, anthropometric, clinical and demographic variables) to develop transparent ML models for cardiovascular disease risk.  Recursive Feature Elimination selected 30 predictors, and the Random Over‑Sampling Examples technique addressed class imbalance.  Multiple models—logistic regression, random forest, support vector machines, XGBoost and LightGBM—were evaluated; XGBoost achieved the highest accuracy (0.8216) and recall (0.8645), while random forest had the highest AUROC (0.8139).  Interpretability analyses using LIME and SHAP identified age, vitamin B12, total cholesterol, C‑reactive protein and waist circumference as the most influential predictors.  The authors conclude that interpretable ML can uncover nutritional and clinical factors that inform prevention strategies.

These examples demonstrate NHANES’s versatility for machine‑learning research.  Because NHANES is a nationally representative, cross‑sectional survey with detailed dietary, laboratory and clinical measurements, it enables researchers to build predictive models, explore novel risk factors and evaluate intervention strategies across diverse health outcomes.
