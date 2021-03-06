if(!require("pacman")) install.packages("pacman")
pacman::p_load(dplyr, ggplot2, glmnet, car, data.table)   #add your packages here

options("scipen"=100, "digits"=4)
options(warn=-1)

library(ggplot2)
library(GGally)
library(randomForest)
library(leaps)
library(Metrics)
library(pROC)

# read data
loan <- fread("loanStats_07_11_clean.csv", stringsAsFactors = T)

# summarize data
summary(loan)

# look at types
str(loan)


## Data Cleaning

# convert term into int
loan$term = as.numeric(gsub("([0-9]+)_.*", "\\1", loan$term))

# convert loan status to binary
loan$default <- ifelse(loan$loan_status=="Charged Off", 1, 0)

# convert date columns to date
loan$issue_d = paste("1", loan$issue_d, sep=" ")
loan$issue_d = as.Date(loan$issue_d, '%d %B %Y')

loan$earliest_cr_line = paste("1", loan$earliest_cr_line, sep=" ")
loan$earliest_cr_line = as.Date(loan$earliest_cr_line, '%d %B %Y')

loan$last_pymnt_d = paste("1", loan$last_pymnt_d, sep=" ")
loan$last_pymnt_d = as.Date(loan$last_pymnt_d, '%d %B %Y')

loan$last_credit_pull_d = paste("1", loan$last_credit_pull_d, sep=" ")
loan$last_credit_pull_d = as.Date(loan$last_credit_pull_d, '%d %B %Y')


# create data to illustrate map
map_data <- loan %>% 
  group_by(addr_state, default) %>%
  tally() %>% 
  group_by(addr_state) %>% 
  mutate(pct = n / sum(n)) %>%
  select(addr_state, default, pct) %>%
  filter(default == 1)

# write.csv(map_data, file = "map_data.csv")


## Hypotheses that I had
### Hypothesis: Some loans were repaid early.


# function to add months to date
add.months= function(date,n) seq(date, by = paste (n, "months"), length = 2)[2]
# add.months(test_date,2)


# find out the date before loan expires
data_length = dim(loan)[1]
final_date = list()

i = 1
while(i < data_length + 1) {
  final_date[[i]] = add.months(loan$issue_d[i], loan$term[i])
  i = i + 1
}

library(zoo)
loan$final_date = as.Date(as.numeric(final_date))



# find out if people paid early or late
difference = loan$final_date - loan$last_pymnt_d
loan$difference_d = difference

sum(difference > 0)
sum(difference < 0)
sum(difference == 0)


From here, it's clear that most people paid off their loans before the term expired, meaning that they'll pay less interest.

### Hypothesis: There is a strong relationship between loan default and grade group

# proportion of defaults in each grade group
proportion <- loan %>%
  group_by(grade, default) %>%
  tally() %>%
  group_by(grade) %>%
  mutate(pct = n / sum(n)) %>%
  mutate(label_y = cumsum(pct))

ggplot(proportion, aes(grade, pct, fill = factor(default, levels = c(1,0)))) +
  geom_bar(stat = "identity") +
  geom_text(aes(label = round(pct, 2), y = label_y), vjust = 1.5, color = "white") +
  scale_fill_manual(values = c("#87CEFF", "#36648B")) +
  labs(fill = "Status") +
  ggtitle('Proportion of Charged Off Loans Per Grade')
# ggsave('proportion.png')


There appears to be a very strong relationship between default and grade.


model.grade = glm(default ~ grade, data=loan, family = 'binomial')
Anova(model.grade)



### Hypothesis: There is a significant difference in default rates for each purpose


# are purpose and default significantly related?
model.purpose = glm(default ~ purpose, data=loan, family = 'binomial')
Anova(model.purpose)

# proportion of defaults for each purpose
proportion <- loan %>%
  group_by(purpose, default) %>%
  tally() %>%
  group_by(purpose) %>%
  mutate(pct = n / sum(n)) %>%
  mutate(label_y = cumsum(pct))

ggplot(proportion, aes(purpose, pct, fill = factor(default, levels = c(1,0)))) +
  geom_bar(stat = "identity") +
  geom_text(aes(label = round(pct, 2), y = label_y), vjust = 1.5, color = "white", size=3) +
  scale_fill_manual(values = c("#87CEFF", "#36648B")) +
  labs(fill = "Status") +
  ggtitle('Proportion of Charged Off Loans Per Purpose') + 
  theme(text = element_text(size=5))
#ggsave('proportion_purpose.png')


## Analyses

### Goal 1: Predict which loans will default


# create dataframe for this analysis
loan_default = loan %>% select(-emp_title, -issue_d, -loan_status, -funded_amnt, -funded_amnt_inv, -total_pymnt, -total_pymnt_inv, -total_rec_prncp, -total_rec_int, -total_rec_late_fee, -recoveries, -collection_recovery_fee, -last_pymnt_d, -last_pymnt_amnt, -last_credit_pull_d, -difference_d, -final_date, -zip_code, -earliest_cr_line, -sub_grade, -addr_state, -emp_length)

# train-test split
set.seed(471)
data_length = dim(loan_default)[1]
propor = sample(1:data_length, 0.7*data_length)

# set up data
x = loan_default %>% select(-default)
y = loan_default %>% select(default)

x_train_default = x[propor,]
x_test_default = x[-propor,]

y_train_default = y[propor,]
y_test_default = y[-propor,]

loan_default_train = loan_default[propor,]
loan_default_test = loan_default[-propor,]


str(x_train_default)
str(y_train_default)


#### Model 1: Logistic Regression using variables from my hypotheses

fit.logit.1 = glm(default ~ grade + purpose + inq_last_6mths, data=loan_default_train, family='binomial')
summary(fit.logit.1)
#fit1.pred = ifelse(predict(fit.logit.5, x_test_default, type='response') >= 0.5, "1", "0") 
#cm2 = table(fit2.pred, unlist(y_test_default)) # confusion matrix: 
#error2 = (cm2[1,2]+cm2[2,1])/length(fit2.pred)

Anova(fit.logit.1)

# rmse
pred1 = predict(fit.logit.1, x_test_default, type='response')
error1 = rmse(unlist(y_test_default), pred1)
error1


#### Model 2: Logistic Lasso

# prepare design matrix
X = model.matrix(default~., loan_default_train)[,-1]
Y = as.numeric(unlist(loan_default_train$default))

fit1.cv <- cv.glmnet(X, Y, alpha=1, family="binomial", nfolds = 10, type.measure = "deviance")  
plot(fit1.cv)


# 1se coefficients
coef.1se = coef(fit1.cv, s="lambda.1se")  
coef.1se = coef.1se[which(coef.1se !=0),] 
coef.1se

# min coefficients
coef.min = coef(fit1.cv, s="lambda.min") 
coef.min = coef.min[which(coef.min !=0), ]
as.matrix(coef.min)

# variables using min
beta.min <- rownames(as.matrix(coef.min)) 
beta.min  

# logistic regression using variables from min
fit.logit.2 <- glm(default ~ loan_amnt + term + int_rate + grade + home_ownership + annual_inc + verification_status + purpose + dti + delinq_2yrs + inq_last_6mths + open_acc + pub_rec + revol_bal + revol_util + total_acc + pub_rec_bankruptcies, family='binomial', data=loan_default_train)
summary(fit.logit.2)


# check which variables are significant
Anova(fit.logit.2)

# rmse
pred2 = predict(fit.logit.2, x_test_default, type='response')
error2 = rmse(unlist(y_test_default), pred2)
error2

# model without non-significant variables
fit.logit.3 <- glm(default ~ term + int_rate + annual_inc + purpose + inq_last_6mths + pub_rec + revol_bal + revol_util + total_acc, family='binomial', data=loan_default_train)
summary(fit.logit.3)


Anova(fit.logit.3)


# rmse
pred3 = predict(fit.logit.3, x_test_default, type='response')
error3 = rmse(unlist(y_test_default), pred3)
error3

# model without non-significant variables
fit.logit.4 <- glm(default ~ term + int_rate + annual_inc + purpose + inq_last_6mths + pub_rec + revol_bal + revol_util, family='binomial', data=loan_default_train)
summary(fit.logit.4)

Anova(fit.logit.4)


# rmse
pred4 = predict(fit.logit.4, x_test_default, type='response')
error4 = rmse(unlist(y_test_default), pred4)
error4


#### Model 3: Random Forest Regressor

ntree = list(300, 400, 500, 600, 700)
errors_p3 = list()

# testing errors for different values of ntrees
length = length(ntree)
for (i in 1:length) {
  rf = randomForest(default ~ ., data=loan_default_train, n_tree = ntree[[i]], type="regression")

  fit.pred = predict(rf, loan_default_test)
  error = rmse(loan_default_test$default, fit.pred)

  addition = cbind(ntree[[i]], error)
  errors_p3 = rbind(errors_p3, addition)
}


# plot errors for different values of ntrees
df = data.frame('Trees' = unlist(errors_p3[,1]), 'TestingError' = unlist(errors_p3[,2]))
ggplot(df, aes(x=Trees, y=TestingError)) + geom_point(col='#36648B', size=5) + ggtitle('Testing Errors of Different Number of Trees')
ggsave('trees.png')

# best rf based on testing error
final_rf = randomForest(default ~ ., data=loan_default_train, n_tree = 300, type='regression')

fit.pred4 = ifelse(predict(final_rf, x_test_default) >= 0.5, "1", "0") 
cm4 = table(fit.pred4, unlist(y_test_default)) # confusion matrix: 
error4 = (cm4[1,2]+cm4[2,1])/length(fit.pred4)
error4

# rmse
pred5 = predict(final_rf, x_test_default)
error5 = rmse(unlist(y_test_default), pred5)

# most important variables
varImpPlot(final_rf)

# plot testing errors of all modelsr
columns = c('Logit1', 'Logit2', 'Logit3', 'Logit4', 'RandomForest')
error_values = c(error1, error2, error3, error4, error5)

df = data.frame('Model' = columns, 'TestingError' = unlist(error_values))
ggplot(df, aes(x=Model, y=TestingError)) + geom_point(col='#36648B', size=5) + ggtitle('Testing Errors of Models')
#ggsave('models_default.png')



### Goal 2: Predict which loans will default

I will use fit.logit.4 from the previous part of the analysis, but will decide on which probability threshold to choose to minimize false 

As an investor, I would want to minimize false negatives because I'd prefer not investing in loans that ended up not defaulting than investing in loans thatI thought would not default but ended up defaulting. However, at the same time, I don't want to give up on investments that I think will default but actually do not.


# roc of test date
fit.logit.roc = roc(loan_default_test$default, pred4, plot=T, col="#36648B")



# FNR and FPR
plot(fit.logit.roc$thresholds, 1-fit.logit.roc$sensitivities,  col="#36648B", pch=16,  
     xlab="Threshold on prob",
     ylab="FNR and FPR",
     main = "Thresholds vs. FNR and FPR")
legend('topright', legend=c("FNR", "FPR"),
       col=c("#36648B", "red"), lty=1, cex=0.8,
       title="Error types", text.font=4)
points(fit.logit.roc$thresholds, 1-fit.logit.roc$specificities, col="red", pch=16, cex=.6)
locator()




# misclassification error with this threshold
fit.pred = ifelse(predict(fit.logit.4, x_test_default) >= 0.14, "1", "0") 
cm = table(fit.pred, unlist(y_test_default)) # confusion matrix: 
mis_rate = (cm[1,2]+cm[2,1])/length(fit.pred)
mis_rate



### Goal 3: Predict how early/late loans will be paid off


# create dataframe for this analysis
loan_time = loan %>% filter(default == 0) %>% select(-emp_title, -issue_d, -loan_status, -funded_amnt, -funded_amnt_inv, -total_pymnt, -total_pymnt_inv, -total_rec_prncp, -total_rec_int, -total_rec_late_fee, -recoveries, -collection_recovery_fee, -last_pymnt_d, -last_pymnt_amnt, -last_credit_pull_d, -default, -final_date, -sub_grade, -zip_code, -addr_state, -earliest_cr_line, -emp_length) 

# convert difference in time to numeric
loan_time$difference_d = as.numeric(loan_time$difference_d)

# train test split
set.seed(471)
data_length = dim(loan_time)[1]
propor = sample(1:data_length, 0.7*data_length)
loan_time_train = loan_time[propor,]
loan_time_test = loan_time[-propor,]

x_time_train = loan_time_train %>% select(-difference_d)
x_time_test = loan_time_test %>% select(-difference_d)

y_time_train = loan_time_train$difference_d
y_time_test = loan_time_test$difference_d

# check the number of people who paid early/late
sum(loan_time$difference_d > 0) # paid early
sum(loan_time$difference_d < 0) # paid late
sum(loan_time$difference_d == 0) # paid on time



str(loan_time)



library(reshape2)

# plots for EDA
first = loan_time %>% select(difference_d, loan_amnt, int_rate, installment, annual_inc, dti, delinq_2yrs)
second = loan_time %>% select(difference_d, inq_last_6mths, open_acc, pub_rec, revol_bal, revol_util, total_acc)
third = loan_time %>% select(difference_d, pub_rec_bankruptcies, grade, home_ownership, verification_status, purpose)

df1 = melt(first, 'difference_d')
df2 = melt(second, 'difference_d')
df3 = melt(third, 'difference_d')

ggplot(df1, aes(value, difference_d)) + 
  geom_point() + 
  facet_wrap(~variable, scales = "free")

ggplot(df2, aes(value, difference_d)) + 
  geom_point() + 
  facet_wrap(~variable, scales = "free")

ggplot(df3, aes(value, difference_d)) + 
  geom_point() + 
  facet_wrap(~variable, scales = "free")



# histogram of difference in dates
qplot(loan_time$difference_d,
      geom="histogram",
      bins=30,
      main="Histogram for Difference in Time", 
      xlab="Difference", 
      fill=I("#36648B"))
#ggsave('Histogram.png')


####Model 1: Exhaustive

# fit exhaustive search model and choose best number of p
fit.exh = regsubsets(difference_d ~., loan_time_train, nvmax=25, method="exhaustive", really.big = T)
f.e = summary(fit.exh)



# plot cp,bic and adj R^2
par(mfrow=c(3,1), mar=c(2.5,4,0.5,1), mgp=c(1.5,0.5,0))   
plot(f.e$cp, xlab="Number of predictors", 
     ylab="cp", col="#36648B", type="p", pch=16)
plot(f.e$bic, xlab="Number of predictors", 
     ylab="bic", col="#36648B", type="p", pch=16)
plot(f.e$adjr2, xlab="Number of predictors", 
     ylab="adjr2", col="#36648B", type="p", pch=16)


# The optimal cp model has all the variables, so I'll limit the model to include 10

# variables in best exhaustive search with 10 variables
fit.exh.var = f.e$which
colnames(fit.exh.var)[fit.exh.var[10,]]

# fit model with those variables
fit.linear.1 = lm(difference_d ~ term + int_rate + purpose + dti + delinq_2yrs + inq_last_6mths + open_acc + revol_util + total_acc, loan_time_train)  
summary(fit.linear.1)

# check significance
Anova(fit.linear.1)

# test error
pred5 = predict(fit.linear.1, x_time_test)
error5 = rmse(unlist(y_time_test), pred5)
error5


#### Model 2: LASSO Regression


# data prep
x_train = model.matrix(loan_time_train$difference_d~., data=loan_time_train)[,-1]
x_test = model.matrix(loan_time_test$difference_d~., data=loan_time_test)[,-1]

# cross validation to select lambda
fit.time.cv = cv.glmnet(x_train, y_time_train, alpha=1, nfolds=10 )
plot(fit.time.cv)


# use lambda that returns min value of mse
coef.min = coef(fit.time.cv, s="lambda.1se")
coef.min = coef.min[which(coef.min!=0),]
var.min = rownames(as.matrix(coef.min))
var.min



# fit lm model
fit.linear.2 = lm(difference_d ~ loan_amnt + term + int_rate + verification_status + dti + inq_last_6mths + open_acc + revol_util + total_acc, data=loan_time_train)
summary(fit.linear.2)



# test error
pred6 = predict(fit.linear.2, x_time_test)
error6 = rmse(unlist(y_time_test), pred6)
error6


Remove insignificant variables


Anova(fit.linear.2)



# fit lm model
fit.linear.3 = lm(difference_d ~ term + int_rate + dti + inq_last_6mths + open_acc + revol_util + total_acc, data=loan_time_train)
summary(fit.linear.3)



# test error
pred7 = predict(fit.linear.3, x_time_test)
error7 = rmse(unlist(y_time_test), pred7)
error7


#### Model 3: Interaction terms

# generate data
interaction_data = model.matrix(difference_d ~.^2, data=loan_time)
x_inter_train = interaction_data[propor,]
x_inter_test = interaction_data[-propor,]

# cross validation to select lambda
fit.inter.cv = cv.glmnet(x_inter_train, y_time_train, alpha=1, nfolds=10 )
plot(fit.inter.cv)



# variables for lambda 1se
coef.1se = coef(fit.inter.cv, s="lambda.1se")
coef.1se = coef.1se[which(coef.1se!=0),]
var.1se = rownames(as.matrix(coef.1se))
var.1se


#data = data.frame(cbind(y_time_train, x_inter_train))

fit.linear.4 = lm(difference_d ~ term + dti + revol_util + loan_amnt*term + term*int_rate + term*verification_status + term*inq_last_6mths + term*total_acc + dti*open_acc + open_acc*revol_util, data=loan_time_train)
summary(fit.linear.4)


# test error
pred8 = predict(fit.linear.4, x_time_test)
error8 = rmse(unlist(y_time_test), pred8)
error8



Anova(fit.linear.4)



#remove insignificant terms

fit.linear.5 = lm(y_time_train ~ term + dti + revol_util + term*int_rate + term*verification_status + term*inq_last_6mths + term*total_acc, data=loan_time_train)
summary(fit.linear.5)



Anova(fit.linear.5)



# test error
pred9 = predict(fit.linear.5, x_time_test)
error9 = rmse(unlist(y_time_test), pred9)
error9



# plot errors of each model
columns = c('Exhaustive', 'LASSO1', 'LASSO2', 'InteractionTerms1', 'InteractionTerms2')
error_values = c(error5, error6, error7, error8, error9)

df = data.frame('Model' = columns, 'TestingError' = unlist(error_values))
ggplot(df, aes(x=Model, y=TestingError)) + geom_point(col='#36648B', size=5) + ggtitle('Testing Errors of Models')
#ggsave('errors_linear.png')



# check residuals
resid = resid(fit.linear.4)
par(mfrow=c(1,2))
plot(resid)
qqnorm(resid)
qqline(resid)
