pipeline {
    agent any
    options { timestamps(); disableConcurrentBuilds(); skipDefaultCheckout(true) }
    parameters {
        booleanParam(name: 'SIMULATE_FAULT', defaultValue: false,
            description: 'Remove health.html to demonstrate failed rollout and automatic rollback')
    }
    triggers { pollSCM('* * * * *') }
    environment { DOCKER_IMAGE = 'abdulkalamay/hospital-appointment-portal' }
    stages {
        stage('1. Clone Code') {
            steps {
                checkout scm
                script { env.IMAGE_TAG = "v1.0.${env.BUILD_NUMBER}" }
                powershell '''
                    if(Test-Path .release-state.json) { Remove-Item -LiteralPath .release-state.json }
                    docker version --format '{{.Server.Version}}'
                    if($LASTEXITCODE -ne 0) { throw 'Docker Engine unavailable.' }
                '''
            }
        }
        stage('2. Build Docker Image') {
            steps {
                powershell '''
                    $image="$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)"
                    docker build --build-arg "RELEASE_VERSION=$env:IMAGE_TAG" --build-arg "SIMULATE_FAULT=$env:SIMULATE_FAULT" -t $image .
                    if($LASTEXITCODE -ne 0) { throw 'Image build failed.' }
                '''
            }
        }
        stage('3. Test Application') {
            steps { powershell '& .\\Test-Image.ps1 -Image "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)" -Release $env:IMAGE_TAG' }
        }
        stage('4. Push Image') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub', usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
                    powershell '& .\\Publish-Image.ps1 -Image "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)"'
                }
            }
        }
        stage('5. Deploy to Kubernetes') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-Hospital.ps1 -Action Deploy -Image "$($env:DOCKER_IMAGE):$($env:IMAGE_TAG)" -Release $env:IMAGE_TAG'
                }
            }
        }
        stage('6. Verify Three Pods and Service') {
            steps {
                withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                    powershell '& .\\Deploy-Hospital.ps1 -Action Verify'
                }
            }
        }
    }
    post {
        failure {
            withCredentials([file(credentialsId: 'kuberconfig', variable: 'KUBECONFIG')]) {
                powershell '& .\\Deploy-Hospital.ps1 -Action Rollback'
            }
        }
        success { echo 'Hospital release verified. NodePort: 30016.' }
    }
}
