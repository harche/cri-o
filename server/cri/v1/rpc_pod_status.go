package v1

import (
	"context"

	pb "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func (s *service) GetPodStatus(
	ctx context.Context, req *pb.GetPodStatusRequest,
) (*pb.GetPodStatusResponse, error) {
	resp, err := s.server.GetPodStatus(ctx, req.PodUid)
	return &resp, err
}
