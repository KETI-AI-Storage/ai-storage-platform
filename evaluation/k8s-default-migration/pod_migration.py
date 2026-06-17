#!/usr/bin/env python3
"""
Kubernetes Pod Migration Module
================================
K8s는 기본 마이그레이션 기능이 없으므로, Pod를 삭제한 후 다른 노드에 재생성하는 방식으로 구현

주요 기능:
- Pod의 현재 상태 및 설정 조회
- Pod 삭제
- 새로운 노드로 Pod 재생성
- 마이그레이션 전후 상태 확인
"""

import time
import json
import argparse
from datetime import datetime
from kubernetes import client, config
from kubernetes.client.rest import ApiException


class PodMigrator:
    """Pod 마이그레이션을 처리하는 클래스"""

    def __init__(self, namespace="default"):
        """
        PodMigrator 초기화

        Args:
            namespace (str): Pod가 위치한 네임스페이스
        """
        try:
            # 클러스터 내부에서 실행시 사용
            config.load_incluster_config()
        except:
            # 로컬 개발 환경에서 실행시 사용
            config.load_kube_config()

        self.v1 = client.CoreV1Api()
        self.namespace = namespace

    def get_pod_info(self, pod_name):
        """
        Pod 정보 조회

        Args:
            pod_name (str): Pod 이름

        Returns:
            dict: Pod 정보
        """
        try:
            pod = self.v1.read_namespaced_pod(name=pod_name, namespace=self.namespace)

            pod_info = {
                "name": pod.metadata.name,
                "namespace": pod.metadata.namespace,
                "node": pod.spec.node_name,
                "status": pod.status.phase,
                "ip": pod.status.pod_ip,
                "labels": pod.metadata.labels,
                "containers": [c.name for c in pod.spec.containers],
                "creation_time": pod.metadata.creation_timestamp
            }

            return pod_info
        except ApiException as e:
            print(f"❌ Error getting pod info: {e}")
            return None

    def get_pod_manifest(self, pod_name):
        """
        Pod의 전체 매니페스트 조회 (재생성을 위해)

        Args:
            pod_name (str): Pod 이름

        Returns:
            V1Pod: Pod 객체
        """
        try:
            pod = self.v1.read_namespaced_pod(name=pod_name, namespace=self.namespace)
            return pod
        except ApiException as e:
            print(f"❌ Error getting pod manifest: {e}")
            return None

    def delete_pod(self, pod_name, grace_period=30):
        """
        Pod 삭제

        Args:
            pod_name (str): 삭제할 Pod 이름
            grace_period (int): 종료 대기 시간(초)

        Returns:
            bool: 삭제 성공 여부
        """
        try:
            print(f"🗑️  Deleting pod '{pod_name}' with grace period {grace_period}s...")

            body = client.V1DeleteOptions(grace_period_seconds=grace_period)
            self.v1.delete_namespaced_pod(
                name=pod_name,
                namespace=self.namespace,
                body=body
            )

            # Pod가 완전히 삭제될 때까지 대기
            print("⏳ Waiting for pod deletion...")
            timeout = grace_period + 60
            start_time = time.time()

            while time.time() - start_time < timeout:
                try:
                    self.v1.read_namespaced_pod(name=pod_name, namespace=self.namespace)
                    time.sleep(2)
                except ApiException as e:
                    if e.status == 404:
                        print("✅ Pod deleted successfully")
                        return True

            print("⚠️  Timeout waiting for pod deletion")
            return False

        except ApiException as e:
            print(f"❌ Error deleting pod: {e}")
            return False

    def create_pod_on_node(self, pod_manifest, target_node=None):
        """
        새로운 노드에 Pod 생성

        Args:
            pod_manifest (V1Pod): Pod 매니페스트
            target_node (str, optional): 대상 노드 이름. None이면 스케줄러가 자동 선택

        Returns:
            bool: 생성 성공 여부
        """
        try:
            # 새로운 Pod 객체 생성 (기존 메타데이터 정리)
            new_pod = client.V1Pod(
                api_version="v1",
                kind="Pod",
                metadata=client.V1ObjectMeta(
                    name=pod_manifest.metadata.name,
                    namespace=self.namespace,
                    labels=pod_manifest.metadata.labels,
                    annotations=pod_manifest.metadata.annotations
                ),
                spec=pod_manifest.spec
            )

            # resourceVersion 등 시스템 필드 제거
            new_pod.metadata.resource_version = None
            new_pod.metadata.uid = None
            new_pod.metadata.creation_timestamp = None
            new_pod.metadata.self_link = None

            # 대상 노드 지정
            if target_node:
                print(f"🎯 Target node specified: {target_node}")
                new_pod.spec.node_name = target_node
                # nodeName을 사용하면 스케줄러를 bypass하므로 nodeSelector 제거
                new_pod.spec.node_selector = None
            else:
                print("🎲 No target node specified, scheduler will decide")
                new_pod.spec.node_name = None

            print(f"🚀 Creating pod '{new_pod.metadata.name}'...")
            created_pod = self.v1.create_namespaced_pod(
                namespace=self.namespace,
                body=new_pod
            )

            print(f"✅ Pod created: {created_pod.metadata.name}")
            return True

        except ApiException as e:
            print(f"❌ Error creating pod: {e}")
            return False

    def wait_for_pod_running(self, pod_name, timeout=300):
        """
        Pod가 Running 상태가 될 때까지 대기

        Args:
            pod_name (str): Pod 이름
            timeout (int): 최대 대기 시간(초)

        Returns:
            bool: Pod가 Running 상태로 전환되었는지 여부
        """
        print(f"⏳ Waiting for pod '{pod_name}' to be running (timeout: {timeout}s)...")
        start_time = time.time()

        while time.time() - start_time < timeout:
            try:
                pod = self.v1.read_namespaced_pod(name=pod_name, namespace=self.namespace)
                status = pod.status.phase

                if status == "Running":
                    print(f"✅ Pod is now running on node: {pod.spec.node_name}")
                    return True
                elif status == "Failed":
                    print(f"❌ Pod failed to start")
                    return False
                else:
                    print(f"⏳ Current status: {status}")
                    time.sleep(5)
            except ApiException as e:
                print(f"⚠️  Error checking pod status: {e}")
                time.sleep(5)

        print(f"⚠️  Timeout waiting for pod to be running")
        return False

    def list_available_nodes(self):
        """
        사용 가능한 노드 목록 조회

        Returns:
            list: 노드 정보 리스트
        """
        try:
            nodes = self.v1.list_node()
            node_list = []

            print("\n📋 Available Nodes:")
            print("-" * 80)

            for node in nodes.items:
                node_info = {
                    "name": node.metadata.name,
                    "status": "Ready" if any(
                        condition.type == "Ready" and condition.status == "True"
                        for condition in node.status.conditions
                    ) else "NotReady",
                    "roles": node.metadata.labels.get("node-role.kubernetes.io/master", "worker"),
                    "cpu": node.status.capacity.get("cpu", "N/A"),
                    "memory": node.status.capacity.get("memory", "N/A")
                }
                node_list.append(node_info)
                print(f"  - {node_info['name']}: {node_info['status']} "
                      f"(CPU: {node_info['cpu']}, Memory: {node_info['memory']})")

            print("-" * 80)
            return node_list

        except ApiException as e:
            print(f"❌ Error listing nodes: {e}")
            return []

    def migrate_pod(self, pod_name, target_node=None, grace_period=30):
        """
        Pod 마이그레이션 실행 (삭제 후 재생성)

        Args:
            pod_name (str): 마이그레이션할 Pod 이름
            target_node (str, optional): 대상 노드 이름
            grace_period (int): Pod 종료 대기 시간

        Returns:
            bool: 마이그레이션 성공 여부
        """
        print("\n" + "="*80)
        print(f"🚀 Starting Pod Migration: {pod_name}")
        print("="*80)

        # 1. 현재 Pod 정보 조회
        print("\n[Step 1/5] Getting current pod information...")
        old_pod_info = self.get_pod_info(pod_name)
        if not old_pod_info:
            print("❌ Failed to get pod information")
            return False

        print(f"\n📌 Current Pod Info:")
        print(f"  - Name: {old_pod_info['name']}")
        print(f"  - Namespace: {old_pod_info['namespace']}")
        print(f"  - Current Node: {old_pod_info['node']}")
        print(f"  - Status: {old_pod_info['status']}")
        print(f"  - IP: {old_pod_info['ip']}")

        # 2. Pod 매니페스트 백업
        print("\n[Step 2/5] Backing up pod manifest...")
        pod_manifest = self.get_pod_manifest(pod_name)
        if not pod_manifest:
            print("❌ Failed to get pod manifest")
            return False
        print("✅ Pod manifest backed up")

        # 3. 사용 가능한 노드 목록 확인
        print("\n[Step 3/5] Checking available nodes...")
        self.list_available_nodes()

        # 4. Pod 삭제
        print(f"\n[Step 4/5] Deleting pod from node '{old_pod_info['node']}'...")
        if not self.delete_pod(pod_name, grace_period):
            print("❌ Failed to delete pod")
            return False

        # 5. 새 노드에 Pod 재생성
        print(f"\n[Step 5/5] Recreating pod...")
        if target_node:
            print(f"  Target node: {target_node}")
        else:
            print(f"  Target node: Auto (scheduler will decide)")

        if not self.create_pod_on_node(pod_manifest, target_node):
            print("❌ Failed to create pod")
            return False

        # 6. Pod가 Running 상태가 될 때까지 대기
        if not self.wait_for_pod_running(pod_name):
            print("❌ Pod failed to reach running state")
            return False

        # 7. 새 Pod 정보 조회
        print("\n[Result] Getting new pod information...")
        new_pod_info = self.get_pod_info(pod_name)
        if not new_pod_info:
            print("⚠️  Warning: Could not retrieve new pod information")
        else:
            print(f"\n📌 New Pod Info:")
            print(f"  - Name: {new_pod_info['name']}")
            print(f"  - Namespace: {new_pod_info['namespace']}")
            print(f"  - New Node: {new_pod_info['node']}")
            print(f"  - Status: {new_pod_info['status']}")
            print(f"  - IP: {new_pod_info['ip']}")

            print("\n" + "="*80)
            if target_node and new_pod_info['node'] == target_node:
                print(f"✅ Migration SUCCESSFUL: {old_pod_info['node']} -> {new_pod_info['node']}")
            elif not target_node:
                print(f"✅ Migration SUCCESSFUL: {old_pod_info['node']} -> {new_pod_info['node']}")
            else:
                print(f"⚠️  Migration completed but pod is on unexpected node: {new_pod_info['node']}")
            print("="*80)

        return True


def main():
    """메인 함수"""
    parser = argparse.ArgumentParser(
        description="Kubernetes Pod Migration Tool - K8s 기본 마이그레이션 없으므로 Pod 삭제 후 재생성",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # Pod를 다른 노드로 마이그레이션 (스케줄러가 자동 선택)
  python3 pod_migration.py --pod pytorch-training-pod --namespace default

  # 특정 노드로 마이그레이션
  python3 pod_migration.py --pod pytorch-training-pod --target-node worker-node-2

  # 노드 목록만 확인
  python3 pod_migration.py --list-nodes
        """
    )

    parser.add_argument(
        "--pod",
        type=str,
        help="마이그레이션할 Pod 이름"
    )

    parser.add_argument(
        "--namespace",
        type=str,
        default="default",
        help="Pod가 위치한 네임스페이스 (기본값: default)"
    )

    parser.add_argument(
        "--target-node",
        type=str,
        help="대상 노드 이름 (지정하지 않으면 스케줄러가 자동 선택)"
    )

    parser.add_argument(
        "--grace-period",
        type=int,
        default=30,
        help="Pod 종료 대기 시간(초) (기본값: 30)"
    )

    parser.add_argument(
        "--list-nodes",
        action="store_true",
        help="사용 가능한 노드 목록만 출력"
    )

    args = parser.parse_args()

    # PodMigrator 초기화
    migrator = PodMigrator(namespace=args.namespace)

    # 노드 목록만 출력하는 경우
    if args.list_nodes:
        migrator.list_available_nodes()
        return

    # Pod 이름이 지정되지 않은 경우
    if not args.pod:
        parser.print_help()
        print("\n❌ Error: --pod argument is required (or use --list-nodes)")
        return

    # Pod 마이그레이션 실행
    success = migrator.migrate_pod(
        pod_name=args.pod,
        target_node=args.target_node,
        grace_period=args.grace_period
    )

    if success:
        print("\n🎉 Pod migration completed successfully!")
    else:
        print("\n❌ Pod migration failed!")
        exit(1)


if __name__ == "__main__":
    main()
