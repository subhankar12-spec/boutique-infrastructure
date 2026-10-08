pipeline {
    agent { label 'terraform-trusted' }
    options { timestamps(); timeout(time: 45, unit: 'MINUTES'); disableConcurrentBuilds(); skipDefaultCheckout(true) }
    parameters {
        choice(name:'ENVIRONMENT',choices:['nonprod','production'])
        booleanParam(name:'APPLY',defaultValue:false,description:'Apply the reviewed saved plan')
    }
    stages {
        stage('Checkout') {
            steps { deleteDir(); checkout scm }
        }
        stage('Validate and plan') {
            steps {
                sh '''set -eu
                    terraform fmt -check -recursive
                    cd "environments/$ENVIRONMENT"
                    terraform init -input=false -backend-config=backend.hcl
                    terraform validate
                    terraform plan -input=false -out=deployment.tfplan
                '''
            }
        }
        stage('Approve apply') {
            when { expression { params.APPLY } }
            steps { input message:'Review this build’s Terraform plan and cost impact. Apply?', submitter:'platform-admins' }
        }
        stage('Apply saved plan') {
            when { expression { params.APPLY } }
            steps { sh 'cd "environments/$ENVIRONMENT" && terraform apply -input=false deployment.tfplan' }
        }
    }
    post { always { sh 'find . -name deployment.tfplan -delete' } }
}
